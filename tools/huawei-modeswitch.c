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
 * Отдельная беда — модем, застрявший без драйвера на storage-интерфейсе: SCSI-сессии
 * нет, и на bulk-OUT он не отвечает вовсе, запись отваливается по таймауту. Столько
 * команд туда ни шли — всё мимо. Поэтому осиротевший интерфейс и таймаут на записи
 * лечатся USB-сбросом (USBDEVFS_RESET): устройство перечисляется заново, ядро
 * возвращает usb-storage, и команду снова есть кому принять.
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
 *   -r       только поговорить с виртуальным CD-ROM модема (SCSI-диалог), не переключать
 *   -c       только послать старый управляющий запрос HuaweiMode, ничего больше
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
		/* Вариант, которым переключается НАША голова (E3372, 14fe -> 1506).
		 * Строго первым: он проверен на железе, и рабочий сценарий не должен
		 * ходить длинной дорогой. Это не тот же байт-в-байт HuaweiNewMode, что
		 * в upstream (см. следующий) — у него обнулён хвост профиля. */
		"вариант E3372 (11 06 20 00 00 01)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* Настоящий HuaweiNewMode из исходников usb_modeswitch: строка
		 * "55534243123456780000000000000011062000000101000100000000000000".
		 * Она же — «HiLink 14db» в разборах E8372h. */
		"HuaweiNewMode upstream (-> HiLink 14db)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x20, 0x00, 0x00, 0x01, 0x01, 0x00, 0x01,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* «Stick/NCM» для E8372h: целевой PID 155e. */
		"NCM/stick (-> 155e)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x30, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* RNDIS: bPcType=00 (Windows). Именно RNDIS видит Windows на E8372h. */
		"RNDIS (bPcType=Windows)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* Вариант из usb-mode.json OpenWrt: bPcType=30 (Gateway). */
		"Gateway (bPcType=30, 01 00 01)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x30, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* Старый PPP-режим. */
		"old PPP (11 06 30 00 00 01)",
		{ 0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
		  0x06, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
		  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	},
	{
		/* Обычный SCSI START STOP UNIT с LOEJ|START — «извлечь диск». Не
		 * Huawei-специфика, а общий приём; длина команды и сама команда
		 * заполнены честно. */
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
	int      ep_in;    /* и bulk-IN: с него читается CSW, см. send_switch */
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
	f->ep_in = -1;
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
			/* bulk (attr&3==2), направление по биту 7 адреса */
			if (in_storage_iface && (attr & 0x03) == 0x02) {
				if (!(addr & 0x80) && f->ep_out < 0)
					f->ep_out = addr;
				else if ((addr & 0x80) && f->ep_in < 0)
					f->ep_in = addr;
			}
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

/*
 * Полноценная транзакция Bulk-Only Transport: CBW -> (данные) -> CSW.
 *
 * Нужна не ради самих данных, а ради того, чтобы поговорить с модемом ровно так,
 * как это делает обычный хост. На голове с виртуальным CD-ROM свистка не общается
 * НИКТО: в ядре нет sr_mod, LUN 0 перечисляется и остаётся нетронутым (устройства
 * /dev/sr* не появляется вовсе), а usb-storage подхватывает только LUN 1 с картой
 * памяти. Windows этот CD-ROM монтирует и читает — там лежит autorun с фирменными
 * драйверами, — и вокруг этого чтения крутится весь сценарий переключения.
 *
 * @return bCSWStatus (0 — команда выполнена), либо -1 при ошибке обмена.
 */
/*
 * Старый HuaweiMode из usb_modeswitch: не bulk-команда, а УПРАВЛЯЮЩИЙ запрос.
 *
 *     libusb_control_transfer(devh, STANDARD|RECIPIENT_DEVICE|ENDPOINT_OUT,
 *                             SET_FEATURE, 1, 0, buffer, 0, 1000)
 *
 * То есть обычный SET_FEATURE(DEVICE_REMOTE_WAKEUP) на устройство. У нас в
 * таблице способов лежал «Huawei legacy», но он слал ту же идею bulk-сообщением
 * — то есть был не тем методом вовсе. Транспорт здесь другой, и на модеме,
 * который bulk-команду принимает и игнорирует, это единственный оставшийся
 * канал, куда мы ещё не стучались.
 */
static int send_huawei_control(const struct found *f)
{
	struct usbdevfs_ctrltransfer ct;
	int fd, rc;

	fd = open(f->node, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "control: open %s: %s\n", f->node, strerror(errno));
		return -1;
	}
	memset(&ct, 0, sizeof(ct));
	ct.bRequestType = 0x00;  /* standard, recipient device, host-to-device */
	ct.bRequest     = 0x03;  /* SET_FEATURE */
	ct.wValue       = 0x0001;/* DEVICE_REMOTE_WAKEUP */
	ct.wIndex       = 0;
	ct.wLength      = 0;
	ct.timeout      = 1000;
	ct.data         = NULL;

	rc = ioctl(fd, USBDEVFS_CONTROL, &ct);
	if (rc < 0)
		printf("control SET_FEATURE(1): %s (на удачном переключении это норма)\n",
		       strerror(errno));
	else
		printf("control SET_FEATURE(1) отправлен\n");
	close(fd);
	return 0;
}

static uint32_t bot_tag = 0x12345678;

static int bot_cmd(int fd, const struct found *f, const uint8_t *cmd, int cmdlen,
		   uint8_t lun, int dir_in, uint8_t *data, int datalen)
{
	struct usbdevfs_bulktransfer bt;
	uint8_t cbw[31], csw[13];
	int rc;

	if (f->ep_in < 0 || f->ep_out < 0)
		return -1;

	memset(cbw, 0, sizeof(cbw));
	memcpy(cbw, "USBC", 4);
	bot_tag++;
	cbw[4] = (uint8_t)(bot_tag);
	cbw[5] = (uint8_t)(bot_tag >> 8);
	cbw[6] = (uint8_t)(bot_tag >> 16);
	cbw[7] = (uint8_t)(bot_tag >> 24);
	cbw[8]  = (uint8_t)(datalen);
	cbw[9]  = (uint8_t)(datalen >> 8);
	cbw[10] = (uint8_t)(datalen >> 16);
	cbw[11] = (uint8_t)(datalen >> 24);
	cbw[12] = dir_in ? 0x80 : 0x00;
	cbw[13] = lun;
	cbw[14] = (uint8_t)cmdlen;
	memcpy(cbw + 15, cmd, cmdlen > 16 ? 16 : cmdlen);

	memset(&bt, 0, sizeof(bt));
	bt.ep = (unsigned int)f->ep_out;
	bt.len = sizeof(cbw);
	bt.timeout = 3000;
	bt.data = cbw;
	if (ioctl(fd, USBDEVFS_BULK, &bt) < 0)
		return -1;

	if (datalen > 0 && data) {
		memset(&bt, 0, sizeof(bt));
		bt.ep = (unsigned int)(dir_in ? f->ep_in : f->ep_out);
		bt.len = (unsigned int)datalen;
		bt.timeout = 5000;
		bt.data = data;
		/* Короткий ответ и стоп на фазе данных — обычное дело, CSW всё скажет. */
		ioctl(fd, USBDEVFS_BULK, &bt);
	}

	memset(&bt, 0, sizeof(bt));
	memset(csw, 0, sizeof(csw));
	bt.ep = (unsigned int)f->ep_in;
	bt.len = sizeof(csw);
	bt.timeout = 5000;
	bt.data = csw;
	rc = ioctl(fd, USBDEVFS_BULK, &bt);
	if (rc < 13 || memcmp(csw, "USBS", 4) != 0)
		return -1;
	return csw[12];
}

/*
 * Прикидываемся нормальным хостом для виртуального CD-ROM модема: спрашиваем
 * готовность, представляемся, читаем размер и сам нулевой сектор. Именно этого
 * общения свистку и не хватает на голове.
 */
static int cdrom_probe(const struct found *f)
{
	uint8_t inquiry[6] = { 0x12, 0, 0, 0, 36, 0 };
	uint8_t tur[6]     = { 0x00, 0, 0, 0, 0, 0 };
	uint8_t readcap[10] = { 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	uint8_t read10[10] = { 0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0 };
	uint8_t buf[2048];
	uint32_t blocks = 0, blksz = 0;
	int fd, ifnum = f->ifnum, st, i;

	fd = open(f->node, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "CD-ROM: open %s: %s\n", f->node, strerror(errno));
		return -1;
	}
	if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifnum) < 0) {
		fprintf(stderr, "CD-ROM: claim: %s\n", strerror(errno));
		close(fd);
		return -1;
	}

	/* Готовность спрашиваем несколько раз: первый ответ у CD-ROM почти всегда
	 * "не готов, носитель менялся" — ровно так же его дёргает любой хост. */
	for (i = 0; i < 5; i++) {
		st = bot_cmd(fd, f, tur, sizeof(tur), 0, 0, NULL, 0);
		printf("CD-ROM: TEST UNIT READY -> %d\n", st);
		if (st == 0) break;
		usleep(300000);
	}

	memset(buf, 0, sizeof(buf));
	st = bot_cmd(fd, f, inquiry, sizeof(inquiry), 0, 1, buf, 36);
	if (st == 0) {
		char vendor[9], product[17];

		memcpy(vendor, buf + 8, 8);  vendor[8] = '\0';
		memcpy(product, buf + 16, 16); product[16] = '\0';
		printf("CD-ROM: INQUIRY -> тип %02x, '%s' '%s'\n", buf[0] & 0x1f, vendor, product);
	} else {
		printf("CD-ROM: INQUIRY -> %d\n", st);
	}

	memset(buf, 0, sizeof(buf));
	st = bot_cmd(fd, f, readcap, sizeof(readcap), 0, 1, buf, 8);
	if (st == 0) {
		blocks = ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16) |
			 ((uint32_t)buf[2] << 8) | buf[3];
		blksz  = ((uint32_t)buf[4] << 24) | ((uint32_t)buf[5] << 16) |
			 ((uint32_t)buf[6] << 8) | buf[7];
		printf("CD-ROM: READ CAPACITY -> %u блоков по %u байт\n", blocks, blksz);
	} else {
		printf("CD-ROM: READ CAPACITY -> %d\n", st);
	}

	if (blksz == 0 || blksz > sizeof(buf))
		blksz = 2048;
	memset(buf, 0, sizeof(buf));
	st = bot_cmd(fd, f, read10, sizeof(read10), 0, 1, buf, (int)blksz);
	printf("CD-ROM: READ(10) сектор 0 -> %d", st);
	if (st == 0) {
		printf(", первые байты:");
		for (i = 0; i < 8; i++)
			printf(" %02x", buf[i]);
	}
	printf("\n");

	ioctl(fd, USBDEVFS_RELEASEINTERFACE, &ifnum);
	close(fd);
	return 0;
}

/*
 * USB-сброс порта: устройство отваливается и перечисляется заново, ядро само
 * прибинживает к нему usb-storage.
 *
 * Нужно вот зачем. Если storage-интерфейс остался без драйвера (например, после
 * нашего же прошлого неудачного захода), модем перестаёт отвечать на bulk-OUT
 * совсем: запись не завершается и отваливается по таймауту, сколько бы команд мы
 * ни слали. SCSI-сессии в этом состоянии нет, и CBW ему просто некуда положить.
 * Сброс возвращает устройство в исходное состояние — ту самую флешку, которая
 * умеет принимать команду.
 *
 * Ждём возвращения по busid: путь в sysfs переживает переподключение, а devnum
 * (и /dev/bus/usb/BBB/DDD) меняется, поэтому вызывающий обязан после нас заново
 * позвать resolve_node().
 */
static int reset_device(struct found *f)
{
	int fd, i;

	fd = open(f->node, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "сброс: open %s: %s\n", f->node, strerror(errno));
		return -1;
	}
	if (ioctl(fd, USBDEVFS_RESET, NULL) < 0) {
		/* ENODEV здесь — норма: устройство уже ушло с шины. */
		if (errno != ENODEV)
			fprintf(stderr, "сброс: %s\n", strerror(errno));
	}
	close(fd);

	for (i = 0; i < 100; i++) {
		usleep(100000);
		if (sysfs_hex(f->busid, "idProduct") >= 0 && resolve_node(f) == 0) {
			char drv[64];

			if (interface_driver(f->busid, f->cfgval, f->ifnum, drv, sizeof(drv)) == 0)
				printf("сброс: устройство вернулось, драйвер %s\n", drv);
			else
				printf("сброс: устройство вернулось, драйвера нет\n");
			return 0;
		}
	}
	fprintf(stderr, "сброс: устройство не вернулось за 10 с\n");
	return -1;
}

/*
 * Возвращает 0, если команда доехала (или устройство исчезло прямо на записи —
 * это успех), и 2, если запись отвалилась по таймауту: значит модем не отвечает
 * и есть смысл его сбросить, а не слать следующую команду в ту же пустоту.
 */
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

	/*
	 * Снимаем halt с endpoint'а перед записью. После unbind'а usb-storage мог
	 * оставить его в стопоре, и тогда любая наша команда упирается в стену.
	 * Устройству без halt'а это ничего не стоит.
	 */
	{
		unsigned int ep = (unsigned int)f->ep_out;

		if (ioctl(fd, USBDEVFS_CLEAR_HALT, &ep) < 0 && errno != ENODEV)
			fprintf(stderr, "предупреждение: clear halt ep 0x%02x: %s\n",
				f->ep_out, strerror(errno));
	}

	memset(&bulk, 0, sizeof(bulk));
	bulk.ep = (unsigned int)f->ep_out;
	bulk.len = 31;
	bulk.timeout = 3000;
	bulk.data = (void *)msg;

	transferred = ioctl(fd, USBDEVFS_BULK, &bulk);
	if (transferred < 0) {
		int err = errno;

		ioctl(fd, USBDEVFS_RELEASEINTERFACE, &ifnum);
		close(fd);
		/*
		 * ENODEV/EIO — модем отвалился прямо в момент приёма команды, для нас
		 * это штатный успех: проверять надо по появлению нового PID.
		 *
		 * ETIMEDOUT — другое дело. Команда никуда не доехала, устройство
		 * молчит на endpoint'е. Слать следующую в ту же пустоту бессмысленно,
		 * сначала надо привести модем в чувство сбросом.
		 */
		if (err == ETIMEDOUT) {
			fprintf(stderr, "bulk: таймаут — модем не отвечает на ep 0x%02x\n",
				f->ep_out);
			return 2;
		}
		fprintf(stderr, "bulk: %s (обычно это норма — модем уже переподключается)\n",
			strerror(err));
		return 0;
	}
	printf("отправлено %d байт в ep 0x%02x\n", transferred, f->ep_out);

	/*
	 * Дочитываем CSW. Bulk-Only Transport — это транзакция из двух шагов: хост
	 * шлёт CBW и ОБЯЗАН забрать 13-байтовый статус со bulk-IN. Мы раньше уходили
	 * сразу после записи, и прошивка вправе была считать транзакцию брошенной и
	 * ничего не делать — ровно то, что наблюдалось на E8372h-153: байты приняты,
	 * эффекта ноль. usb_modeswitch статус читает, и мы теперь тоже.
	 *
	 * Ошибка здесь ничего не отменяет: на удачном переключении модем отваливается
	 * прямо в этот момент, и ENODEV — самый желанный исход.
	 */
	if (f->ep_in >= 0) {
		struct usbdevfs_bulktransfer csw;
		uint8_t buf[13];
		int got;

		memset(&csw, 0, sizeof(csw));
		memset(buf, 0, sizeof(buf));
		csw.ep = (unsigned int)f->ep_in;
		csw.len = sizeof(buf);
		csw.timeout = 3000;
		csw.data = buf;

		got = ioctl(fd, USBDEVFS_BULK, &csw);
		if (got < 0) {
			printf("CSW не прочитан (%s) — на удачном переключении это норма\n",
			       strerror(errno));
		} else if (got >= 13 && memcmp(buf, "USBS", 4) == 0) {
			/* Последний байт CSW — bCSWStatus: 0 команда принята. */
			printf("CSW: статус %d (%s)\n", buf[12],
			       buf[12] == 0 ? "команда принята" : "команда отвергнута");
		} else {
			printf("CSW: %d байт, не похоже на статус\n", got);
		}
	}

	ioctl(fd, USBDEVFS_RELEASEINTERFACE, &ifnum);
	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	struct found f;
	int dry_run = 0, i, wait_secs = 20, custom_ok = 0, did_reset = 0, probe_only = 0, ctrl_only = 0;
	uint8_t custom[31];
	char busid_arg[32] = "";

	memset(&f, 0, sizeof(f));
	memset(custom, 0, sizeof(custom));

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-n") == 0) {
			dry_run = 1;
		} else if (strcmp(argv[i], "-r") == 0) {
			probe_only = 1;
		} else if (strcmp(argv[i], "-c") == 0) {
			ctrl_only = 1;
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

	/*
	 * Осиротевший storage-интерфейс — само по себе признак беды: модем в таком
	 * состоянии на bulk-OUT не отвечает вовсе. Сбрасываем сразу, до первой
	 * команды, чтобы ядро вернуло usb-storage и SCSI-сессию.
	 */
	{
		char drv[64];

		if (interface_driver(f.busid, f.cfgval, f.ifnum, drv, sizeof(drv)) != 0) {
			printf("storage-интерфейс без драйвера — сбрасываю устройство\n");
			if (reset_device(&f) == 0)
				did_reset = 1;
		}
	}

	/*
	 * Прежде чем что-то переключать, ведём себя как обычный хост: читаем
	 * виртуальный CD-ROM. На голове его не читает никто (нет sr_mod), и это
	 * единственное заметное отличие от Windows, где свисток переключается сам.
	 */
	if (resolve_node(&f) == 0) {
		if (unbind_if_needed(&f) != 0)
			fprintf(stderr, "unbind не удался, пробуем claim всё равно\n");
		cdrom_probe(&f);
	}
	if (ctrl_only) {
		send_huawei_control(&f);
		if (wait_for_switch(f.busid, wait_secs) >= 0)
			printf("переключился: PID стал %04x\n",
			       (unsigned)sysfs_hex(f.busid, "idProduct"));
		else
			printf("PID не изменился за %d с\n", wait_secs);
		return 0;
	}
	if (probe_only) {
		printf("PID сейчас: %04x\n", (unsigned)sysfs_hex(f.busid, "idProduct"));
		return 0;
	}

	for (i = 0; i < (custom_ok ? 1 : N_METHODS); i++) {
		const uint8_t *msg = custom_ok ? custom : methods[i].msg;
		int pid, rc;

		printf("--- способ %d: %s\n", i + 1,
		       custom_ok ? "сообщение из -m" : methods[i].name);

		/* devnum мог смениться, если модем переподключился от прошлой попытки. */
		if (resolve_node(&f) != 0) {
			fprintf(stderr, "%s пропал с шины\n", f.busid);
			return 2;
		}
		if (unbind_if_needed(&f) != 0)
			fprintf(stderr, "unbind не удался, пробуем claim всё равно\n");
		rc = send_switch(&f, msg);

		/*
		 * Таймаут: команда не доехала. Один раз за весь запуск пробуем
		 * сбросить модем и повторить этот же способ — дальше смысла нет,
		 * иначе на мёртвом устройстве мы просто трижды сбросим шину.
		 */
		if (rc == 2 && !did_reset) {
			did_reset = 1;
			if (reset_device(&f) == 0 && resolve_node(&f) == 0) {
				if (unbind_if_needed(&f) != 0)
					fprintf(stderr, "unbind не удался, пробуем claim всё равно\n");
				rc = send_switch(&f, msg);
			}
		}
		if (rc != 0)
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

	/* Последним — другой транспорт: управляющий запрос вместо bulk-команды. */
	if (!custom_ok) {
		printf("--- последний способ: управляющий запрос HuaweiMode\n");
		if (resolve_node(&f) == 0) {
			send_huawei_control(&f);
			if (wait_for_switch(f.busid, wait_secs) >= 0) {
				printf("переключился: PID стал %04x\n",
				       (unsigned)sysfs_hex(f.busid, "idProduct"));
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
