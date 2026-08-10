/*
 * huawei-modeswitch — переводит Huawei-модем из storage-режима (12d1:14fe и т.п.)
 * в режим с AT/PPP-портами (12d1:1506) без usb_modeswitch и без Frida.
 *
 * Ровно то же, что делает usb_modeswitch: 31-байтовая SCSI-команда (CBW) в bulk-OUT
 * endpoint mass-storage-интерфейса, отправленная напрямую через usbfs
 * (/dev/bus/usb/BBB/DDD). После неё модем сам переподключается уже с новым PID,
 * поэтому ошибка на записи вида ENODEV/EIO — это НЕ сбой, а ожидаемый результат.
 *
 * Перед этим интерфейс нужно по-настоящему освободить от usb-storage: одного
 * USBDEVFS_DISCONNECT (soft-disconnect на уровне usbfs) недостаточно — сразу после
 * enumerate() ядро может ещё гонять SCSI-команды (INQUIRY/READ CAPACITY) в отдельном
 * потоке usb-storage, и наша claim+bulk проезжает мимо, ничего не меняя (PID остаётся
 * прежним). Поэтому сначала — настоящий unbind через sysfs
 * (/sys/bus/usb/drivers/usb-storage/unbind), с ожиданием, что драйвер правда отвалился.
 *
 * Сборка: tools/build-tools.sh (статически, aarch64).
 * Запуск на голове: huawei-modeswitch [-n] [busid, например 2-1]
 *   -n   только показать, что найдено и что было бы сделано, ничего не отправлять
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/usbdevice_fs.h>

#define HUAWEI_VENDOR 0x12d1
#define SYSFS_USB_DEVICES "/sys/bus/usb/devices"
#define SYSFS_STORAGE_UNBIND "/sys/bus/usb/drivers/usb-storage/unbind"

/* PID'ы, в которых модем притворяется флешкой/CD-ROM и AT-портов не отдаёт. */
static const uint16_t storage_pids[] = { 0x14fe, 0x1f01, 0x1f02, 0x1446, 0x14ad, 0x1c0b };

/*
 * Сообщение из upstream-конфига usb_modeswitch для Huawei (TargetProduct=0x1506).
 * Это стандартный CBW: signature "USBC", tag, длина, флаги + SCSI-команда 0x11 0x06.
 */
static const uint8_t switch_msg[31] = {
	0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
	0x06, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

/* Дескрипторы разбираем сами, чтобы не тянуть linux/usb/ch9.h из чужого sysroot. */
struct desc_hdr { uint8_t bLength; uint8_t bDescriptorType; };

#define DT_DEVICE    0x01
#define DT_CONFIG    0x02
#define DT_INTERFACE 0x04
#define DT_ENDPOINT  0x05

struct found {
	uint16_t vid, pid;
	int      cfgval;  /* bConfigurationValue (обычно 1) */
	int      ifnum;   /* mass-storage интерфейс (bInterfaceNumber) */
	int      ep_out;  /* его bulk-OUT endpoint */
	char     busid[32];  /* sysfs busid, например "2-1"; пусто, если найдено по devnode */
	char     node[512];  /* /dev/bus/usb/BBB/DDD */
};

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static int is_storage_pid(uint16_t pid)
{
	size_t i;
	for (i = 0; i < sizeof(storage_pids) / sizeof(storage_pids[0]); i++)
		if (storage_pids[i] == pid)
			return 1;
	return 0;
}

/*
 * usbfs отдаёт по read() дескриптор устройства, а следом все конфигурации.
 * Идём по ним линейно и запоминаем bConfigurationValue, первый mass-storage
 * интерфейс (класс 0x08) и его bulk-OUT endpoint.
 */
static int parse_descriptors(int fd, struct found *f)
{
	uint8_t buf[4096];
	ssize_t n = read(fd, buf, sizeof(buf));
	ssize_t i = 0;
	int in_storage_iface = 0;

	if (n < 18)
		return -1;

	f->ifnum = -1;
	f->ep_out = -1;
	f->cfgval = 1; /* разумный дефолт для однoконфигурационных устройств */

	while (i + 2 <= n) {
		const struct desc_hdr *h = (const struct desc_hdr *)(buf + i);

		if (h->bLength < 2 || i + h->bLength > n)
			break;

		if (h->bDescriptorType == DT_DEVICE && h->bLength >= 18) {
			f->vid = le16(buf + i + 8);
			f->pid = le16(buf + i + 10);
		} else if (h->bDescriptorType == DT_CONFIG && h->bLength >= 6) {
			f->cfgval = buf[i + 5];
		} else if (h->bDescriptorType == DT_INTERFACE && h->bLength >= 9) {
			uint8_t ifnum = buf[i + 2];
			uint8_t iclass = buf[i + 5];

			in_storage_iface = (iclass == 0x08);
			if (in_storage_iface && f->ifnum < 0)
				f->ifnum = ifnum;
		} else if (h->bDescriptorType == DT_ENDPOINT && h->bLength >= 7) {
			uint8_t addr = buf[i + 2];
			uint8_t attr = buf[i + 3];

			/* bulk (attr&3==2) и направление OUT (бит 7 сброшен) */
			if (in_storage_iface && (attr & 0x03) == 0x02 &&
			    !(addr & 0x80) && f->ep_out < 0)
				f->ep_out = addr;
		}
		i += h->bLength;
	}
	return f->ifnum >= 0 ? 0 : -1;
}

/*
 * Ищем первый Huawei в storage-режиме через sysfs (а не перебором /dev/bus/usb) —
 * так заодно получаем busid, нужный для настоящего unbind ниже. Каталоги устройств
 * в sysfs называются вроде "2-1" (без двоеточия — это отличает их от подкаталогов
 * интерфейсов вида "2-1:1.0").
 */
static int find_device(struct found *f)
{
	DIR *d = opendir(SYSFS_USB_DEVICES);
	struct dirent *e;
	int rc = -1;

	if (!d) {
		fprintf(stderr, "нет %s: %s\n", SYSFS_USB_DEVICES, strerror(errno));
		return -1;
	}

	while ((e = readdir(d)) != NULL) {
		char path[300], line[64];
		FILE *fp;
		unsigned vid = 0, pid = 0, busnum = 0, devnum = 0;

		if (e->d_name[0] == '.' || strchr(e->d_name, ':'))
			continue;

		snprintf(path, sizeof(path), "%s/%s/idVendor", SYSFS_USB_DEVICES, e->d_name);
		fp = fopen(path, "r");
		if (!fp)
			continue;
		if (fgets(line, sizeof(line), fp))
			vid = (unsigned)strtoul(line, NULL, 16);
		fclose(fp);
		if (vid != HUAWEI_VENDOR)
			continue;

		snprintf(path, sizeof(path), "%s/%s/idProduct", SYSFS_USB_DEVICES, e->d_name);
		fp = fopen(path, "r");
		if (fp) {
			if (fgets(line, sizeof(line), fp))
				pid = (unsigned)strtoul(line, NULL, 16);
			fclose(fp);
		}
		if (!is_storage_pid((uint16_t)pid))
			continue;

		snprintf(path, sizeof(path), "%s/%s/busnum", SYSFS_USB_DEVICES, e->d_name);
		fp = fopen(path, "r");
		if (fp) {
			if (fgets(line, sizeof(line), fp))
				busnum = (unsigned)strtoul(line, NULL, 10);
			fclose(fp);
		}
		snprintf(path, sizeof(path), "%s/%s/devnum", SYSFS_USB_DEVICES, e->d_name);
		fp = fopen(path, "r");
		if (fp) {
			if (fgets(line, sizeof(line), fp))
				devnum = (unsigned)strtoul(line, NULL, 10);
			fclose(fp);
		}
		if (!busnum || !devnum)
			continue;

		snprintf(f->busid, sizeof(f->busid), "%s", e->d_name);
		snprintf(f->node, sizeof(f->node), "/dev/bus/usb/%03u/%03u", busnum, devnum);
		rc = 0;
		break;
	}
	closedir(d);
	return rc;
}

/* Драйвер, привязанный к интерфейсу busid:cfgval.ifnum, или NULL, если не привязан. */
static int interface_driver(const char *busid, int cfgval, int ifnum, char *out, size_t outlen)
{
	char path[300], link[256];
	ssize_t n;

	snprintf(path, sizeof(path), "%s/%s:%d.%d/driver", SYSFS_USB_DEVICES, busid, cfgval, ifnum);
	n = readlink(path, link, sizeof(link) - 1);
	if (n < 0)
		return -1;
	link[n] = '\0';
	snprintf(out, outlen, "%s", strrchr(link, '/') ? strrchr(link, '/') + 1 : link);
	return 0;
}

/*
 * Настоящий unbind через sysfs — в отличие от USBDEVFS_DISCONNECT это не soft-trick
 * на уровне открытого usbfs-хендла, а обычный путь ядра: драйверный ->disconnect()
 * реально отрабатывает, и usb-storage перестаёт гонять SCSI-команды по интерфейсу
 * до того, как мы полезем в него с CLAIMINTERFACE/BULK.
 */
static int unbind_if_needed(const struct found *f)
{
	char drv[64], id[64];
	int fd, i;

	if (f->busid[0] == '\0') {
		fprintf(stderr, "нет busid (устройство передано по devnode) — unbind пропущен, "
				"полагаемся на USBDEVFS_DISCONNECT\n");
		return 0;
	}
	if (interface_driver(f->busid, f->cfgval, f->ifnum, drv, sizeof(drv)) != 0) {
		printf("интерфейс %s:%d.%d уже без драйвера\n", f->busid, f->cfgval, f->ifnum);
		return 0;
	}
	if (strcmp(drv, "usb-storage") != 0) {
		printf("интерфейс %s:%d.%d занят драйвером '%s' (не usb-storage) — не трогаю\n",
		       f->busid, f->cfgval, f->ifnum, drv);
		return 0;
	}

	snprintf(id, sizeof(id), "%s:%d.%d", f->busid, f->cfgval, f->ifnum);
	fd = open(SYSFS_STORAGE_UNBIND, O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s (нет прав на unbind?)\n",
			SYSFS_STORAGE_UNBIND, strerror(errno));
		return -1;
	}
	if (write(fd, id, strlen(id)) < 0) {
		fprintf(stderr, "unbind %s: %s\n", id, strerror(errno));
		close(fd);
		return -1;
	}
	close(fd);

	/* Ждём, пока драйвер реально отвалится — ->disconnect() не мгновенен. */
	for (i = 0; i < 30; i++) {
		if (interface_driver(f->busid, f->cfgval, f->ifnum, drv, sizeof(drv)) != 0) {
			printf("usb-storage отвязан от %s\n", id);
			return 0;
		}
		usleep(100000);
	}
	fprintf(stderr, "предупреждение: usb-storage не отвязался от %s за 3с, пробуем всё равно\n", id);
	return 0;
}

static int send_switch(const struct found *f)
{
	struct usbdevfs_ioctl detach;
	struct usbdevfs_bulktransfer bulk;
	int fd, ifnum = f->ifnum, transferred;

	fd = open(f->node, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", f->node, strerror(errno));
		return 1;
	}

	/*
	 * Подстраховка на случай, если sysfs-unbind выше не сработал (нет прав,
	 * SELinux и т.п.) или busid не был известен: старый usbfs soft-disconnect,
	 * лучше, чем ничего.
	 */
	memset(&detach, 0, sizeof(detach));
	detach.ifno = ifnum;
	detach.ioctl_code = USBDEVFS_DISCONNECT;
	if (ioctl(fd, USBDEVFS_IOCTL, &detach) < 0 && errno != ENODATA)
		fprintf(stderr, "предупреждение: disconnect ifno=%d: %s\n", ifnum, strerror(errno));

	if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifnum) < 0) {
		fprintf(stderr, "claim ifno=%d: %s\n", ifnum, strerror(errno));
		close(fd);
		return 1;
	}

	memset(&bulk, 0, sizeof(bulk));
	bulk.ep = (unsigned int)f->ep_out;
	bulk.len = sizeof(switch_msg);
	bulk.timeout = 3000;
	bulk.data = (void *)switch_msg;

	transferred = ioctl(fd, USBDEVFS_BULK, &bulk);
	if (transferred < 0) {
		/*
		 * Модем часто отваливается прямо в момент приёма команды — для нас
		 * это штатный успех, проверять надо по появлению нового PID.
		 */
		fprintf(stderr, "bulk: %s (обычно это норма — модем уже переподключается)\n",
			strerror(errno));
	} else {
		printf("отправлено %d байт в ep 0x%02x\n", transferred, f->ep_out);
	}

	ioctl(fd, USBDEVFS_RELEASEINTERFACE, &ifnum);
	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	struct found f;
	int dry_run = 0, i;
	char busid_arg[32] = "";

	memset(&f, 0, sizeof(f));

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-n") == 0)
			dry_run = 1;
		else
			snprintf(busid_arg, sizeof(busid_arg), "%s", argv[i]);
	}

	if (busid_arg[0]) {
		char path[300], line[64];
		FILE *fp;
		unsigned busnum = 0, devnum = 0;
		int fd;

		snprintf(path, sizeof(path), "%s/%s/busnum", SYSFS_USB_DEVICES, busid_arg);
		fp = fopen(path, "r");
		if (fp) { if (fgets(line, sizeof(line), fp)) busnum = (unsigned)strtoul(line, NULL, 10); fclose(fp); }
		snprintf(path, sizeof(path), "%s/%s/devnum", SYSFS_USB_DEVICES, busid_arg);
		fp = fopen(path, "r");
		if (fp) { if (fgets(line, sizeof(line), fp)) devnum = (unsigned)strtoul(line, NULL, 10); fclose(fp); }
		if (!busnum || !devnum) {
			fprintf(stderr, "%s: не нашёл busnum/devnum в sysfs\n", busid_arg);
			return 1;
		}
		snprintf(f.busid, sizeof(f.busid), "%s", busid_arg);
		snprintf(f.node, sizeof(f.node), "/dev/bus/usb/%03u/%03u", busnum, devnum);

		fd = open(f.node, O_RDWR);
		if (fd < 0)
			fd = open(f.node, O_RDONLY);
		if (fd < 0) {
			fprintf(stderr, "open %s: %s\n", f.node, strerror(errno));
			return 1;
		}
		if (parse_descriptors(fd, &f) != 0) {
			fprintf(stderr, "%s: mass-storage интерфейс не найден\n", f.node);
			close(fd);
			return 2;
		}
		close(fd);
	} else if (find_device(&f) != 0) {
		fprintf(stderr, "Huawei в storage-режиме не найден "
				"(модем уже переключён или не воткнут)\n");
		return 2;
	} else {
		int fd = open(f.node, O_RDWR);

		if (fd < 0)
			fd = open(f.node, O_RDONLY);
		if (fd < 0) {
			fprintf(stderr, "open %s: %s\n", f.node, strerror(errno));
			return 1;
		}
		if (parse_descriptors(fd, &f) != 0) {
			fprintf(stderr, "%s: mass-storage интерфейс не найден\n", f.node);
			close(fd);
			return 2;
		}
		close(fd);
	}

	printf("устройство: %s (busid %s)  %04x:%04x  cfg %d  storage-интерфейс %d  bulk-OUT ep 0x%02x\n",
	       f.node, f.busid[0] ? f.busid : "?", f.vid, f.pid, f.cfgval, f.ifnum, f.ep_out);

	if (f.ep_out < 0) {
		fprintf(stderr, "bulk-OUT endpoint не найден — отправлять команду некуда\n");
		return 3;
	}
	if (f.vid != HUAWEI_VENDOR)
		fprintf(stderr, "предупреждение: это не Huawei (vid %04x)\n", f.vid);

	{
		char drv[64];
		if (f.busid[0] && interface_driver(f.busid, f.cfgval, f.ifnum, drv, sizeof(drv)) == 0)
			printf("сейчас интерфейс занят драйвером: %s\n", drv);
		else
			printf("сейчас интерфейс без драйвера\n");
	}

	if (dry_run) {
		printf("dry-run: unbind/команда не выполняются\n");
		return 0;
	}

	if (unbind_if_needed(&f) != 0)
		fprintf(stderr, "unbind не удался, пробуем claim всё равно (может не сработать)\n");

	return send_switch(&f);
}
