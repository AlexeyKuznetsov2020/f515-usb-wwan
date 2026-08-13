/*
 * huawei-modeswitch — переводит Huawei-модем из storage-режима (12d1:14fe и т.п.)
 * в режим с AT/PPP-портами (12d1:1506) без usb_modeswitch и без Frida.
 *
 * Ровно то же, что делает usb_modeswitch: 31-байтовая SCSI-команда (CBW) в bulk-OUT
 * endpoint mass-storage-интерфейса, отправленная напрямую через usbfs
 * (/dev/bus/usb/BBB/DDD). После неё модем сам переподключается уже с новым PID,
 * поэтому ошибка на записи вида ENODEV/EIO — это НЕ сбой, а ожидаемый результат.
 *
 * Команда не одна. Прошивки Huawei за годы разошлись, и та, что переключает E3372
 * (12d1:14fe), молча игнорируется E8372h-153 (12d1:1f01): байты уходят, устройство
 * не реагирует и остаётся флешкой. Поэтому способы перебираются по очереди, и после
 * каждого мы ЖДЁМ и проверяем PID в sysfs — переподключение занимает секунды, а не
 * мгновение (upstream usb_modeswitch держит для этих PID CheckSuccess=20).
 * Если не помог ни один — печатаем полный разбор дескрипторов: без него по одному
 * «не сработало» на чужой голове диагностировать нечего.
 *
 * Перед этим интерфейс нужно по-настоящему освободить от usb-storage: одного
 * USBDEVFS_DISCONNECT (soft-disconnect на уровне usbfs) недостаточно — сразу после
 * enumerate() ядро может ещё гонять SCSI-команды (INQUIRY/READ CAPACITY) в отдельном
 * потоке usb-storage, и наша claim+bulk проезжает мимо, ничего не меняя (PID остаётся
 * прежним). Поэтому сначала — настоящий unbind через sysfs
 * (/sys/bus/usb/drivers/usb-storage/unbind), с ожиданием, что драйвер правда отвалился.
 *
 * Сборка: tools/build-tools.sh (статически, aarch64).
 * Запуск на голове: huawei-modeswitch [-n] [-w СЕК] [-m ХЕКС] [busid, например 2-1]
 *   -n       только показать, что найдено и что было бы сделано, ничего не отправлять
 *   -w СЕК   сколько ждать нового PID после каждой команды (по умолчанию 20)
 *   -m ХЕКС  послать ровно это сообщение (62 hex-символа) и никакое другое —
 *            чтобы проверить чужой рецепт, не пересобирая бинарь
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
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
 * Способы переключения, по порядку. Все три — стандартный CBW: signature "USBC",
 * tag, длина передачи, флаги, длина команды и сама SCSI-команда.
 *
 * Первым идёт тот, что работает на нашей голове (E3372, 14fe -> 1506): менять
 * порядок нельзя, иначе рабочий сценарий начнёт ходить длинной дорогой.
 */
struct method {
	const char *name;
	uint8_t     msg[31];
};

static const struct method methods[] = {
	{
		/* HuaweiNewMode (-J у usb_modeswitch): им переключается почти вся
		 * серия E3372/E8372 по upstream-конфигу 12d1:1f01. */
		"HuaweiNewMode (11 06 20 00 00 01)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* Старый HuaweiMode (-H): то же семейство команд, но без хвоста
		 * 20 00 00 01. Прошивки постарше понимают только его. */
		"Huawei legacy (11 06)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* Обычный SCSI START STOP UNIT с LOEJ|START — «извлечь диск».
		 * Не Huawei-специфика, а общий приём: часть свистков уходит из
		 * CD-ROM-режима именно от него. Здесь честно заполнены длина
		 * команды (6) и сама команда 1b 00 00 00 02 00. */
		"SCSI eject (1b 00 00 00 02 00)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x1b,
		  0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	}
};

#define N_METHODS ((int)(sizeof(methods) / sizeof(methods[0])))

/* Дескрипторы разбираем сами, чтобы не тянуть linux/usb/ch9.h из чужого sysroot. */
struct desc_hdr { uint8_t bLength; uint8_t bDescriptorType; };

#define DT_DEVICE    0x01
#define DT_CONFIG    0x02
#define DT_INTERFACE 0x04
#define DT_ENDPOINT  0x05

struct found {
	uint16_t vid, pid;
	int      cfgval;   /* bConfigurationValue конфигурации со storage-интерфейсом */
	int      ifnum;    /* mass-storage интерфейс (bInterfaceNumber) */
	int      ep_out;   /* его bulk-OUT endpoint */
	int      nconfigs; /* bNumConfigurations: больше одной — есть что переключать */
	char     busid[32];  /* sysfs busid, например "2-1"; пусто, если найдено по devnode */
	char     node[512];  /* /dev/bus/usb/BBB/DDD */
	char     dump[2048]; /* разбор дескрипторов — печатаем, только если всё провалилось */
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
static void dumpf(struct found *f, const char *fmt, ...)
{
	va_list ap;
	size_t len = strlen(f->dump);

	if (len + 1 >= sizeof(f->dump))
		return;
	va_start(ap, fmt);
	vsnprintf(f->dump + len, sizeof(f->dump) - len, fmt, ap);
	va_end(ap);
}

static int parse_descriptors(int fd, struct found *f)
{
	uint8_t buf[4096];
	ssize_t n = read(fd, buf, sizeof(buf));
	ssize_t i = 0;
	int in_storage_iface = 0;
	int cur_cfg = 1;

	if (n < 18)
		return -1;

	f->ifnum = -1;
	f->ep_out = -1;
	f->cfgval = 1; /* разумный дефолт для однoконфигурационных устройств */
	f->nconfigs = 1;
	f->dump[0] = '\0';

	while (i + 2 <= n) {
		const struct desc_hdr *h = (const struct desc_hdr *)(buf + i);

		if (h->bLength < 2 || i + h->bLength > n)
			break;

		if (h->bDescriptorType == DT_DEVICE && h->bLength >= 18) {
			f->vid = le16(buf + i + 8);
			f->pid = le16(buf + i + 10);
			f->nconfigs = buf[i + 17];
			dumpf(f, "  устройство %04x:%04x, конфигураций: %d\n",
			      f->vid, f->pid, f->nconfigs);
		} else if (h->bDescriptorType == DT_CONFIG && h->bLength >= 6) {
			/*
			 * cfgval нужен для пути вида "2-1:1.0", то есть это номер той
			 * конфигурации, в которой лежит storage-интерфейс, а не последней
			 * встреченной. Раньше он перетирался каждым CONFIG-дескриптором:
			 * на многоконфигурационном устройстве unbind шёл бы по
			 * несуществующему пути и молча не делал ничего.
			 */
			cur_cfg = buf[i + 5];
			dumpf(f, "  конфигурация %d: интерфейсов %d\n", cur_cfg, buf[i + 4]);
		} else if (h->bDescriptorType == DT_INTERFACE && h->bLength >= 9) {
			uint8_t ifnum = buf[i + 2];
			uint8_t iclass = buf[i + 5];

			dumpf(f, "    интерфейс %d alt %d: класс %02x/%02x/%02x\n",
			      ifnum, buf[i + 3], iclass, buf[i + 6], buf[i + 7]);
			in_storage_iface = (iclass == 0x08);
			if (in_storage_iface && f->ifnum < 0) {
				f->ifnum = ifnum;
				f->cfgval = cur_cfg;
			}
		} else if (h->bDescriptorType == DT_ENDPOINT && h->bLength >= 7) {
			uint8_t addr = buf[i + 2];
			uint8_t attr = buf[i + 3];

			dumpf(f, "      ep 0x%02x %s\n", addr,
			      (attr & 0x03) == 0x02 ? "bulk" :
			      (attr & 0x03) == 0x03 ? "interrupt" : "прочий");
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

/* Читает одно шестнадцатеричное поле устройства из sysfs; -1, если устройства нет. */
static int sysfs_hex(const char *busid, const char *attr)
{
	char path[300], line[64];
	FILE *fp;
	int v = -1;

	snprintf(path, sizeof(path), "%s/%s/%s", SYSFS_USB_DEVICES, busid, attr);
	fp = fopen(path, "r");
	if (!fp)
		return -1;
	if (fgets(line, sizeof(line), fp))
		v = (int)strtoul(line, NULL, 16);
	fclose(fp);
	return v;
}

/* Пересчитывает /dev/bus/usb/BBB/DDD: после переподключения devnum меняется. */
static int resolve_node(struct found *f)
{
	char path[300], line[64];
	FILE *fp;
	unsigned busnum = 0, devnum = 0;

	snprintf(path, sizeof(path), "%s/%s/busnum", SYSFS_USB_DEVICES, f->busid);
	fp = fopen(path, "r");
	if (fp) { if (fgets(line, sizeof(line), fp)) busnum = (unsigned)strtoul(line, NULL, 10); fclose(fp); }
	snprintf(path, sizeof(path), "%s/%s/devnum", SYSFS_USB_DEVICES, f->busid);
	fp = fopen(path, "r");
	if (fp) { if (fgets(line, sizeof(line), fp)) devnum = (unsigned)strtoul(line, NULL, 10); fclose(fp); }
	if (!busnum || !devnum)
		return -1;
	snprintf(f->node, sizeof(f->node), "/dev/bus/usb/%03u/%03u", busnum, devnum);
	return 0;
}

/*
 * Ждём, пока модем вернётся на шину с НЕ-storage PID.
 *
 * Проверять сразу после команды бессмысленно: устройство сначала отваливается,
 * потом заново перечисляется, и всё это занимает секунды — у upstream
 * usb_modeswitch для этих же PID стоит CheckSuccess=20. Пропажа каталога в sysfs
 * тоже не ответ: это середина переподключения, надо дождаться возвращения.
 *
 * Возвращает новый PID, или -1, если за отведённое время ничего не изменилось.
 */
static int wait_for_switch(const char *busid, int secs)
{
	int i, gone = 0;

	for (i = 0; i < secs * 10; i++) {
		int pid = sysfs_hex(busid, "idProduct");

		if (pid < 0) {
			gone = 1;          /* переподключается — это хороший знак */
		} else if (!is_storage_pid((uint16_t)pid)) {
			return pid;
		} else if (gone) {
			/* Вернулся — и снова флешкой. Способ не сработал. */
			return -1;
		}
		usleep(100000);
	}
	return -1;
}

/*
 * Переключение сменой конфигурации USB. Не Huawei-специфика: если устройство
 * заявляет больше одной конфигурации, «рабочая» может быть просто второй, и
 * никакие SCSI-команды для этого не нужны. Ядро само переберёт драйверы заново.
 */
static int try_config_switch(const struct found *f, int cfg)
{
	char path[300], val[16];
	int fd;

	snprintf(path, sizeof(path), "%s/%s/bConfigurationValue", SYSFS_USB_DEVICES, f->busid);
	fd = open(path, O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}
	snprintf(val, sizeof(val), "%d", cfg);
	if (write(fd, val, strlen(val)) < 0) {
		fprintf(stderr, "запись cfg %d: %s\n", cfg, strerror(errno));
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

static int send_switch(const struct found *f, const uint8_t *msg)
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
	bulk.len = 31;
	bulk.timeout = 3000;
	bulk.data = (void *)msg;

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
	int dry_run = 0, i, wait_secs = 20, custom_ok = 0;
	uint8_t custom[31];
	char busid_arg[32] = "";

	memset(&f, 0, sizeof(f));
	memset(custom, 0, sizeof(custom));

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-n") == 0) {
			dry_run = 1;
		} else if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) {
			wait_secs = atoi(argv[++i]);
			if (wait_secs < 1)
				wait_secs = 1;
		} else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
			const char *h = argv[++i];
			int k;

			if (strlen(h) != 62) {
				fprintf(stderr, "-m: нужно ровно 62 hex-символа (31 байт), а не %zu\n",
					strlen(h));
				return 1;
			}
			for (k = 0; k < 31; k++) {
				char pair[3] = { h[k * 2], h[k * 2 + 1], '\0' };
				char *end;

				custom[k] = (uint8_t)strtoul(pair, &end, 16);
				if (*end) {
					fprintf(stderr, "-m: '%s' — не hex\n", pair);
					return 1;
				}
			}
			custom_ok = 1;
		} else {
			snprintf(busid_arg, sizeof(busid_arg), "%s", argv[i]);
		}
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
			fprintf(stderr, "%s", f.dump);
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
			fprintf(stderr, "%s", f.dump);
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
		printf("%s", f.dump);
		return 0;
	}

	if (f.busid[0] == '\0') {
		/*
		 * Без busid проверять результат нечем (sysfs-путь неизвестен), так что
		 * остаётся старое поведение: одна команда вслепую.
		 */
		if (unbind_if_needed(&f) != 0)
			fprintf(stderr, "unbind не удался, пробуем claim всё равно\n");
		return send_switch(&f, custom_ok ? custom : methods[0].msg);
	}

	for (i = 0; i < (custom_ok ? 1 : N_METHODS); i++) {
		const uint8_t *msg = custom_ok ? custom : methods[i].msg;
		int pid;

		printf("--- способ %d: %s\n", i + 1,
		       custom_ok ? "сообщение из -m" : methods[i].name);

		/* devnum мог смениться, если модем переподключился от прошлой попытки. */
		if (resolve_node(&f) != 0) {
			fprintf(stderr, "%s пропал с шины\n", f.busid);
			return 2;
		}
		if (unbind_if_needed(&f) != 0)
			fprintf(stderr, "unbind не удался, пробуем claim всё равно\n");
		if (send_switch(&f, msg) != 0)
			continue;

		pid = wait_for_switch(f.busid, wait_secs);
		if (pid >= 0) {
			printf("переключился: PID стал %04x\n", (unsigned)pid);
			return 0;
		}
		printf("PID не изменился за %d с\n", wait_secs);
	}

	/*
	 * Отдельным заходом, уже после всех SCSI-команд: смена конфигурации меняет
	 * состояние устройства сильнее прочего, и начинать с неё не стоит.
	 */
	if (!custom_ok && f.nconfigs > 1) {
		int cfg;

		for (cfg = 1; cfg <= f.nconfigs; cfg++) {
			int pid;

			if (cfg == f.cfgval)
				continue;
			printf("--- способ %d: конфигурация USB %d из %d\n",
			       N_METHODS + cfg, cfg, f.nconfigs);
			if (try_config_switch(&f, cfg) != 0)
				continue;
			pid = wait_for_switch(f.busid, wait_secs);
			if (pid >= 0) {
				printf("переключился: PID стал %04x\n", (unsigned)pid);
				return 0;
			}
			printf("PID не изменился за %d с\n", wait_secs);
		}
	}

	fprintf(stderr, "ни один способ не сработал, модем остался в storage-режиме\n");
	fprintf(stderr, "разбор дескрипторов (пришли эти строки — по ним видно, что за режим):\n");
	fprintf(stderr, "%s", f.dump);
	return 4;
}
