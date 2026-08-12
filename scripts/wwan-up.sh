#!/system/bin/sh
# wwan-up.sh — подъём USB-модема как WWAN на голове F515.
#
# Умеет два типа модемов и определяет тип сам:
#   hilink — модем сам роутер и отдаёт себя как USB-сетевую карту (ZTE MF833R и любой
#            другой CDC-Ethernet/RNDIS): нужен только DHCP, ядро уже умеет всё само;
#   ppp    — модем отдаёт AT/PPP-порты (Huawei E17x/E1750/E3272, 12d1:*): нужен
#            modeswitch, два модуля ядра и дозвон через pppd.
# Принудительно тип задаётся через WWAN_MODE=hilink|ppp.
#
# Скрипт идёт стадиями и каждую сначала ПРОВЕРЯЕТ: уже сделано — пропускает,
# не хватает предусловия — останавливается с понятным сообщением и подсказкой,
# а не падает где-то в середине. Повторный запуск безопасен.
#
#   wwan-up.sh              подъём
#   wwan-up.sh --check      только диагностика, ничего не меняет
#   wwan-up.sh --system     дополнительно отдать интернет приложениям Android
#   wwan-up.sh --down       остановить pppd (маршруты не трогает)
#   wwan-up.sh --boot       режим автозапуска: вокруг insmod ставится маркер, по
#                           которому wwan-boot.sh после ребута понимает, что голова
#                           упала именно на загрузке модуля (см. docs/autostart.md)
#
# Настройки: переменные окружения или /data/local/tmp/wwan.conf (см. wwan.conf.example).

DIR=$(cd "$(dirname "$0")" && pwd)
TMP=/data/local/tmp
LOG=${WWAN_LOG:-$TMP/wwan.log}
PPP_LOG=$TMP/ppp.log
CONF=${WWAN_CONF:-$TMP/wwan.conf}
STATE=${WWAN_STATE:-$DIR/state}
INFLIGHT=$STATE/insmod-inflight

[ -f "$CONF" ] && . "$CONF"

APN=${WWAN_APN:-internet}
PPP_USER=${WWAN_USER:-}
PPP_PASS=${WWAN_PASS:-}
DIAL=${WWAN_DIAL:-*99#}
# Куда класть маршрут модема. 99 = «legacy_system» в терминах Android; таблица
# служебная, основной main при этом не трогается и управляющий adb не рвётся.
TABLE=${WWAN_TABLE:-99}
# Запасные значения для hilink-ветки, если DHCP почему-то ничего не отдал.
# Сколько секунд перебирать ttyUSB в поисках отвечающего на AT, прежде чем считать
# модем мёртвым. Бюджет по времени, а не по числу попыток: портов у устройства может
# быть и три, и круг по ним сам по себе занимает несколько секунд. На стенде порт
# отзывается на первом же круге, потолок нужен только чтобы не висеть на мёртвом.
AT_WAIT_SECS=${WWAN_AT_WAIT_SECS:-20}
HILINK_ADDR=${WWAN_HILINK_ADDR:-192.168.0.178}
HILINK_GW=${WWAN_HILINK_GW:-192.168.0.1}

CHECK_ONLY=0
DO_SYSTEM=0
DO_DOWN=0
BOOT_MODE=0
for a in "$@"; do
	case "$a" in
	-c | --check)  CHECK_ONLY=1 ;;
	-s | --system) DO_SYSTEM=1 ;;
	--down)        DO_DOWN=1 ;;
	--boot)        BOOT_MODE=1 ;;
	-h | --help)   sed -n '2,30p' "$0"; exit 0 ;;
	*) echo "неизвестный аргумент: $a (см. --help)"; exit 64 ;;
	esac
done

# ---------------------------------------------------------------- вывод/логи --
STAGE_NO=0

say()   { echo "$*"; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }
stage() {
	STAGE_NO=$((STAGE_NO + 1))
	say ""
	say "== $STAGE_NO. $1"
	busy "$1"
}

# Признак «подъём прямо сейчас идёт» — для иконки в статус-баре. Первое слово в
# файле это наш pid, дальше название текущей стадии. Пока модем не
# зарегистрировался в сети, tboxwire по этому файлу гоняет палки по кругу вместо
# крестика: видно, что процесс идёт, а не «сети нет и не будет». Именно pid, а не
# отметка времени: сверив cmdline, tboxwire отличает живой подъём от брошенного
# файла (state/ переживает и падение скрипта, и перезагрузку), и как только
# скрипт умер — палки сразу сменяются честным крестиком. Проверке --check
# анимация не положена: она ничего не поднимает.
busy() {
	[ "$CHECK_ONLY" = 0 ] || return 0
	mkdir -p "$STATE" 2>/dev/null
	echo "$$ $1" >"$STATE/busy" 2>/dev/null
	# Стадия приложения («жду adbd, раскладываю файлы, жду догрузки системы») на этом
	# закончилась: дальше показываем подъём. Признак снимается здесь, а не в самом
	# приложении, потому что между его запуском и первой стадией лежат ещё 45 секунд
	# задержки в wwan-boot.sh, и всё это время анимация приложения уместна.
	echo 0 >"$STATE/appboot" 2>/dev/null
}
# Вышли как угодно, в том числе через die, — подъём больше не идёт.
idle() { [ "$CHECK_ONLY" = 0 ] && echo "0 -" >"$STATE/busy" 2>/dev/null; }
trap idle EXIT
ok()    { say "   [ ok ] $*"; }
skip()  { say "   [ -- ] $*"; }
warn()  { say "   [warn] $*"; }
# die <что не так> <что делать>
die() {
	say "   [FAIL] $1"
	[ -n "$2" ] && say "          -> $2"
	exit 1
}

# Действие, которое в режиме --check только печатается.
do_it() {
	if [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] $*"
		return 0
	fi
	"$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ хелперы --
# Сетевой интерфейс HiLink-модема ищем по драйверу, а не по вендору/MAC/имени:
# HiLink-модемы любого производителя отдают себя как USB CDC-Ethernet устройство
# и привязываются к cdc_ether (реже rndis_host/cdc_ncm); ни MAC, ни имя
# интерфейса, ни VID между моделями не совпадают, а класс USB-устройства — да.
find_hilink_iface() {
	for d in /sys/class/net/*; do
		[ -f "$d/address" ] || continue
		drv=$(readlink -f "$d/device/driver" 2>/dev/null) || continue
		dev=$(readlink -f "$d/device" 2>/dev/null)
		case "$dev" in
		*/usb*/*) ;;   # интерфейс должен висеть на USB, а не быть встроенным
		*) continue ;;
		esac
		case "$(basename "$drv")" in
		cdc_ether | rndis_host | cdc_ncm)
			HILINK_IF=$(basename "$d")
			return 0 ;;
		esac
	done
	return 1
}

# Каталог модема в sysfs + его VID/PID (Huawei-семейство).
find_usb_dev() {
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		v=$(cat "$d/idVendor" 2>/dev/null)
		[ "$v" = "12d1" ] || continue
		USB_DEV=$d
		USB_VID=$v
		USB_PID=$(cat "$d/idProduct" 2>/dev/null)
		return 0
	done
	return 1
}

# ttyUSB, соответствующий интерфейсу с заданным bInterfaceProtocol
# (10 = modem/PPP-порт, 12 = PCUI/AT-порт).
#
# Работает только на «новых» свистках (E303, E3272, E353). Старая серия — E173
# (12d1:1c05), E1750, E220 — выставляет 0xFF у ВСЕХ интерфейсов сразу, никакого
# протокола 12 там нет вовсе, и догадка уходит в никуда. Поэтому результат этой
# функции — только первый кандидат, а не приговор: реальный порт ищется опросом,
# см. at_candidates() и стадию «SIM и регистрация в сети».
port_for_proto() {
	for i in "$USB_DEV":*; do
		[ -f "$i/bInterfaceProtocol" ] || continue
		[ "$(cat "$i/bInterfaceProtocol" 2>/dev/null)" = "$1" ] || continue
		for t in "$i"/ttyUSB*; do
			[ -e "$t" ] || continue
			echo "/dev/$(basename "$t")"
			return 0
		done
	done
	return 1
}

# Все ttyUSB этого устройства — в том порядке, в каком имеет смысл спрашивать AT:
# сначала догадка по протоколу, потом остальные, модемный последним (на нём AT
# обычно тоже отвечает, но занимать его до дозвона незачем).
at_candidates() {
	_ac_list=""
	[ -c "$CTRL_TTY" ] && _ac_list="$CTRL_TTY"
	for _ac_t in $(ls -d "$USB_DEV":*/ttyUSB* 2>/dev/null | sed 's|.*/||' | sort -u); do
		[ -c "/dev/$_ac_t" ] || continue
		[ "/dev/$_ac_t" = "$CTRL_TTY" ] && continue
		[ "/dev/$_ac_t" = "$MODEM_TTY" ] && continue
		_ac_list="$_ac_list /dev/$_ac_t"
	done
	[ -c "$MODEM_TTY" ] && [ "$MODEM_TTY" != "$CTRL_TTY" ] &&
		_ac_list="$_ac_list $MODEM_TTY"
	echo $_ac_list
}

ko_vermagic() { grep -ao 'vermagic=[^[:space:]]*' "$1" 2>/dev/null | head -1 | cut -d= -f2; }

# Загрузка модуля с переводом ошибок insmod на человеческий.
load_module() {
	_ko=$1
	_name=$2
	_probe=$3 # путь в sysfs/procfs, по которому видно, что модуль уже работает

	if [ -n "$_probe" ] && [ -e "$_probe" ]; then
		skip "$_name: уже загружен ($_probe на месте)"
		return 0
	fi
	if lsmod 2>/dev/null | grep -q "^$_name "; then
		skip "$_name: уже в lsmod"
		return 0
	fi
	[ -f "$_ko" ] || die "$_name: нет файла $_ko" \
		"положи .ko рядом со скриптом или укажи WWAN_MODDIR"

	# Главная проверка перед insmod: vermagic. Несовпадение = гарантированная
	# порча памяти ядра вплоть до паники, поэтому дальше не идём.
	_vm=$(ko_vermagic "$_ko")
	_kr=$(uname -r)
	if [ -z "$_vm" ]; then
		warn "$_name: в модуле нет vermagic — проверить не получилось"
	elif [ "$_vm" != "$_kr" ]; then
		die "$_name: модуль собран для ядра '$_vm', а на голове '$_kr'" \
			"пересобрать модули под это ядро (modules/build-cfi.sh)"
	else
		ok "$_name: vermagic совпадает ($_vm)"
	fi
	if [ "$(grep -ac '__cfi_check' "$_ko" 2>/dev/null)" = "0" ]; then
		die "$_name: в модуле нет __cfi_check" \
			"ядро собрано с CONFIG_CFI_CLANG и не-CFI модули не принимает — собирать modules/build-cfi.sh"
	fi

	if [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] insmod $_ko"
		return 0
	fi

	# Единственная операция во всём скрипте, которая может уронить ядро целиком
	# (и тем самым устроить бутлуп при автозапуске). Маркер ставится ДО и
	# снимается ПОСЛЕ, sync — чтобы он пережил панику; wwan-boot.sh по
	# оставшемуся маркеру понимает, что прошлый заход умер именно здесь.
	if [ "$BOOT_MODE" = 1 ]; then
		mkdir -p "$STATE" 2>/dev/null
		echo "$(date '+%F %T') $_name $_ko" >"$INFLIGHT"
		sync
	fi
	_err=$(insmod "$_ko" 2>&1)
	_rc=$?
	if [ "$BOOT_MODE" = 1 ]; then
		rm -f "$INFLIGHT"
		sync
	fi

	if [ $_rc -eq 0 ]; then
		ok "$_name: загружен"
		return 0
	fi
	case "$_err" in
	*"File exists"* | *"уже существует"*)
		skip "$_name: уже загружен"
		return 0 ;;
	*"Invalid module format"* | *"invalid module format"*)
		die "$_name: ядро отвергло формат модуля ($_err)" \
			"почти всегда это несовпадение vermagic/раскладки struct module — пересобрать" ;;
	*"Unknown symbol"*)
		die "$_name: не хватает символов ядра ($_err)" \
			"смотри dmesg: ядро печатает, какого именно символа нет" ;;
	*"Operation not permitted"*)
		die "$_name: insmod запрещён ($_err)" \
			"проверь, что шелл root и SELinux не Enforcing" ;;
	*)
		die "$_name: insmod не сработал ($_err)" "смотри dmesg" ;;
	esac
}

# Одна AT-команда, ответ на stdout. Порт переводим в raw без эха, иначе ответы
# перемешиваются с эхом и распарсить их нельзя. Скорость не трогаем: у USB-модема
# она виртуальная, а toybox stty на этом драйвере её выставить не может и тогда
# отбрасывает всю команду целиком. -iuclc обязателен — иначе порт отдаёт ответы
# в нижнем регистре ("ok" вместо "OK").
#
# Открытие порта и чтение из него живут в подоболочке, и это не косметика:
# скрипт, запущенный через `adb shell 'sh wwan-up.sh'` (без pty), оказывается
# лидером сессии без управляющего терминала, и тогда открытие /dev/ttyUSB1
# делает этот порт управляющим терминалом. Дальше любое чтение из фоновой
# группы процессов ловит SIGTTIN и останавливается НАВСЕГДА - скрипт висит на
# стадии 8 и его приходится убивать. Форкнутый ребёнок лидером сессии не
# является, поэтому ctty не захватывается вообще. Под приложением проблема не
# видна: там pty уже есть, и ttyUSB управляющим стать не может.
# --foreground - второй слой той же защиты: toybox timeout по умолчанию уводит
# ребёнка в собственную группу процессов, то есть в фоновую.
at() {
	_tty=$1
	_cmd=$2
	_wait=${3:-2}
	[ -c "$_tty" ] || return 1
	stty -F "$_tty" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1
	(
		exec 9<>"$_tty" || exit 1
		timeout --foreground 1 cat <&9 >/dev/null 2>&1
		printf '%s\r' "$_cmd" >&9
		timeout --foreground "$_wait" cat <&9 | tr -d '\r'
	)
}

iface_addr() { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

# Отвечает ли DNS-сервер. На голове нет ни nslookup, ни dig — есть только
# busybox (и то не всегда), поэтому «проверить не смогли» и «не отвечает» надо
# различать: молча считать сервер мёртвым и переписывать netfilter нельзя.
dns_answers() {
	if have nslookup; then
		timeout 5 nslookup connectivitycheck.gstatic.com "$1" >/dev/null 2>&1
	elif have busybox; then
		timeout 5 busybox nslookup connectivitycheck.gstatic.com "$1" >/dev/null 2>&1
	else
		warn "нечем проверить DNS $1 (нет nslookup/busybox) — считаю, что не отвечает"
		return 1
	fi
}

# Маршрут по умолчанию через модем в заданную таблицу. У ppp0 маршрут
# point-to-point (без шлюза), у hilink за интерфейсом настоящий L3-роутер.
add_default() {
	_tbl=$1
	_metric=$2
	if [ "$MODE" = ppp ]; then
		do_it ip route replace default dev "$WAN_IF" table "$_tbl" metric "$_metric"
	else
		do_it ip route replace default via "$GW" dev "$WAN_IF" table "$_tbl" metric "$_metric"
	fi
}

# ------------------------------------------------------------------- --down --
if [ "$DO_DOWN" = 1 ]; then
	stage "остановка"
	_pids=$(pidof pppd 2>/dev/null)
	if [ -n "$_pids" ]; then
		kill $_pids && ok "pppd остановлен (pid $_pids)"
	else
		skip "pppd не запущен"
	fi
	say ""
	say "Маршруты, правила и hilink-интерфейс скрипт НЕ трогает. Убрать вручную:"
	say "   ip route del default table $TABLE"
	say "   ip rule del oif ppp0 table $TABLE"
	exit 0
fi

say "=================================================================="
say "wwan-up $(date '+%F %T')  APN=$APN  check=$CHECK_ONLY  system=$DO_SYSTEM boot=$BOOT_MODE"

# --------------------------------------------------------- окружение --------
stage "окружение"

[ "$(id -u)" = "0" ] || die "нужен root (сейчас uid=$(id -u))" \
	"adbd на этой прошивке уже root: adb shell должен давать uid=0"
ok "root"

KREL=$(uname -r)
ok "ядро $KREL"

if have getenforce; then
	_se=$(getenforce 2>/dev/null)
	case "$_se" in
	Enforcing) warn "SELinux Enforcing — insmod может быть запрещён" ;;
	*)         ok "SELinux $_se" ;;
	esac
fi

_missing=""
for t in ip timeout; do
	have "$t" || _missing="$_missing $t"
done
[ -z "$_missing" ] || die "в системе нет:$_missing" "без них подъём невозможен"
ok "базовые утилиты на месте"

# Иконку поднимаем ЗДЕСЬ, а не в конце вместе с итогом: подъём модема после
# перезагрузки занимает до минуты с лишним (загрузка модулей, modeswitch,
# регистрация в сети, дозвон), и всё это время в статус-баре не должно быть
# пусто — по бегущим палкам видно, что процесс идёт. К самому подъёму иконка
# отношения не имеет, поэтому молча и без права что-либо уронить.
if [ "$CHECK_ONLY" = 0 ] && [ -x "$DIR/tbox-icon.sh" ]; then
	sh "$DIR/tbox-icon.sh" auto >/dev/null 2>&1 &
fi

# --------------------------------------------------------- модем -----------
stage "какой модем подключён"

MODE=${WWAN_MODE:-}
if [ -n "$MODE" ]; then
	ok "тип задан вручную: WWAN_MODE=$MODE"
	[ "$MODE" = hilink ] && { find_hilink_iface || die "hilink-интерфейс не найден" \
		"убери WWAN_MODE, чтобы скрипт определил тип сам"; }
	[ "$MODE" = ppp ] && { find_usb_dev || die "модем 12d1:* не найден" \
		"убери WWAN_MODE, чтобы скрипт определил тип сам"; }
elif find_hilink_iface; then
	MODE=hilink
	ok "HiLink-модем: сетевой интерфейс $HILINK_IF (драйвер cdc_ether/rndis)"
elif find_usb_dev; then
	MODE=ppp
	ok "найден $USB_VID:$USB_PID ($(basename "$USB_DEV")) — ветка AT/PPP"
else
	say "   видимые USB-устройства:"
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		say "      $(basename "$d")  $(cat "$d/idVendor"):$(cat "$d/idProduct" 2>/dev/null)" \
			"\"$(cat "$d/product" 2>/dev/null)\""
	done
	say "   сетевые интерфейсы:"
	for d in /sys/class/net/*; do
		[ -f "$d/address" ] || continue
		say "      $(basename "$d") driver=$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")"
	done
	die "модем не найден ни как сетевой интерфейс, ни как 12d1:*" \
		"проверь кабель и питание USB-порта; Huawei после перевтыкания возвращается в storage-режим"
fi

# ================================================================ HILINK ====
if [ "$MODE" = hilink ]; then
	WAN_IF=$HILINK_IF

	stage "адрес по DHCP на $WAN_IF"
	ADDR=$(iface_addr "$WAN_IF")
	if [ -n "$ADDR" ]; then
		skip "$WAN_IF уже с адресом: $ADDR"
	elif [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] ip link set $WAN_IF up + udhcpc"
	else
		ip link set "$WAN_IF" up
		i=0
		while [ $i -lt 30 ]; do
			[ "$(cat /sys/class/net/$WAN_IF/carrier 2>/dev/null)" = "1" ] && break
			sleep 1
			i=$((i + 1))
		done
		[ "$(cat /sys/class/net/$WAN_IF/carrier 2>/dev/null)" = "1" ] ||
			warn "carrier так и не появился за 30 с — пробуем DHCP всё равно"

		# HiLink-модем сам раздаёт DHCP и делает NAT, но udhcpc здесь без
		# default-скрипта: аренду получает, а применить её некому — разбираем
		# вывод и настраиваем интерфейс руками.
		have busybox || die "нет busybox — нечем взять DHCP-аренду" \
			"задай адрес вручную: WWAN_HILINK_ADDR/WWAN_HILINK_GW"
		LEASE=$(busybox udhcpc -i "$WAN_IF" -q -n -f 2>&1)
		ADDR=$(echo "$LEASE" | sed -n 's/.*lease of \([0-9.]*\) obtained from \([0-9.]*\).*/\1/p' | tail -1)
		GW=$(echo "$LEASE" | sed -n 's/.*lease of \([0-9.]*\) obtained from \([0-9.]*\).*/\2/p' | tail -1)
		if [ -z "$ADDR" ]; then
			warn "DHCP молчит, беру запасной адрес $HILINK_ADDR/$HILINK_GW"
			ADDR=$HILINK_ADDR
			GW=$HILINK_GW
		fi
		ip addr replace "$ADDR/24" dev "$WAN_IF"
		ok "$WAN_IF: $ADDR (шлюз $GW)"
	fi

	stage "шлюз"
	if [ -z "$GW" ]; then
		# Адрес уже был (или его поставил прошлый запуск) — шлюз берём из
		# существующего маршрута, а если и его нет, то у HiLink-модемов это
		# всегда .1 своей же подсети.
		GW=$(ip route show table all 2>/dev/null |
			sed -n "s/^default via \([0-9.]*\) dev $WAN_IF.*/\1/p" | head -1)
		[ -n "$GW" ] || GW=$(echo "${ADDR:-$HILINK_ADDR}" | sed 's/\.[0-9]*$/.1/')
	fi
	[ -n "$ADDR" ] || ADDR=$(iface_addr "$WAN_IF")
	ok "шлюз модема $GW"

	# DNS у HiLink-модема раздаёт он сам (прокси на своём же адресе).
	DNS=$GW
fi

# =================================================================== PPP ====
if [ "$MODE" = ppp ]; then
	WAN_IF=ppp0

	stage "файлы"
	MODDIR=${WWAN_MODDIR:-$DIR}
	[ -f "$MODDIR/usbserialmerged2.ko" ] || MODDIR=$TMP
	KO_USB=$MODDIR/usbserialmerged2.ko
	KO_PPP=$MODDIR/ppp_async.ko
	MODESWITCH=${WWAN_MODESWITCH:-$MODDIR/huawei-modeswitch}
	DIAL_SH=${WWAN_DIALSH:-$DIR/dial.sh}
	[ -f "$DIAL_SH" ] || DIAL_SH=$TMP/dial.sh

	for f in "$KO_USB" "$KO_PPP" "$DIAL_SH"; do
		[ -f "$f" ] || die "нет файла $f" "разложи содержимое scripts/ и modules/prebuilt/ в $TMP"
	done
	[ -x "$DIAL_SH" ] || chmod 755 "$DIAL_SH" 2>/dev/null
	ok "модули и dial.sh найдены в $MODDIR"
	[ -f "$MODESWITCH" ] || warn "нет $MODESWITCH — если модем окажется в storage-режиме, переключить будет нечем"

	_missing=""
	for t in insmod lsmod pppd stty; do
		have "$t" || _missing="$_missing $t"
	done
	[ -z "$_missing" ] || die "в системе нет:$_missing" \
		"без них PPP-подъём невозможен; pppd обычно /system/bin/pppd"

	stage "режим модема"
	NEED_SWITCH=0
	case "$USB_PID" in
	1506 | 1465 | 140c | 1c05 | 14ac) ok "режим с AT/PPP-портами" ;;
	14fe | 1f01 | 1f02 | 1446 | 14ad | 1c0b)
		NEED_SWITCH=1
		warn "модем в storage-режиме — нужен modeswitch" ;;
	*)
		warn "PID $USB_PID незнакомый — пробуем как есть" ;;
	esac

	if [ "$NEED_SWITCH" = 0 ]; then
		skip "modeswitch не требуется"
	else
		[ -f "$MODESWITCH" ] || die "нужен modeswitch, но $MODESWITCH отсутствует" \
			"собрать tools/build-tools.sh и положить бинарь рядом"
		[ -x "$MODESWITCH" ] || chmod 755 "$MODESWITCH"
		if [ "$CHECK_ONLY" = 1 ]; then
			say "   [dry ] $MODESWITCH"
		else
			"$MODESWITCH" 2>&1 | while read -r l; do say "   $l"; done
			# Модем переподключается с новым PID — ждём появления.
			i=0
			while [ $i -lt 20 ]; do
				sleep 1
				if find_usb_dev && [ "$USB_PID" != "14fe" ]; then break; fi
				i=$((i + 1))
			done
			find_usb_dev || die "после modeswitch модем пропал с шины" \
				"вытащить и вставить модем, затем запустить скрипт заново"
			case "$USB_PID" in
			14fe | 1f01 | 1f02 | 1446 | 14ad | 1c0b)
				die "modeswitch не сработал, PID остался $USB_PID" \
					"проверь, что ядро не держит usb-storage, и попробуй ещё раз" ;;
			esac
			ok "переключён в $USB_VID:$USB_PID"
		fi
	fi

	stage "модуль usbserial+option"
	# rmmod на этой голове роняет ядро — выгружать модули нельзя ни при каких условиях.
	load_module "$KO_USB" usbserialmerged2 /sys/bus/usb/drivers/option

	stage "последовательные порты"
	if [ "$CHECK_ONLY" = 1 ] && [ "$NEED_SWITCH" = 1 ]; then
		# В сухом прогоне modeswitch только печатается, но не выполняется, поэтому
		# модем так и остался флешкой и AT/PPP-интерфейсов на шине физически нет.
		# Это не поломка, а прямое следствие --check, и советовать тут dmesg вредно.
		skip "модем ещё в storage-режиме (в --check modeswitch не выполняется) — портам взяться неоткуда"
	elif [ "$CHECK_ONLY" = 1 ] && [ ! -e /sys/bus/usb/drivers/option ]; then
		skip "модуль не загружен (--check), порты проверить нечем"
	else
		i=0
		while [ $i -lt 15 ]; do
			[ -c /dev/ttyUSB0 ] && break
			sleep 1
			i=$((i + 1))
		done

		if [ ! -c /dev/ttyUSB0 ]; then
			# Драйвер есть, но интерфейсы не подхватились — чаще всего PID не в
			# таблице option. Это лечится штатным механизмом new_id.
			warn "ttyUSB не появились, пробуем добавить $USB_VID:$USB_PID через new_id"
			for p in /sys/bus/usb-serial/drivers/option1/new_id /sys/bus/usb/drivers/option/new_id; do
				[ -w "$p" ] && do_it sh -c "echo '$USB_VID $USB_PID' > $p"
			done
			sleep 2
		fi
		[ -c /dev/ttyUSB0 ] || die "порты ttyUSB не появились" \
			"смотри dmesg: привязался ли option к интерфейсам $(basename "$USB_DEV"):1.*"

		MODEM_TTY=$(port_for_proto 10) || MODEM_TTY=/dev/ttyUSB0
		CTRL_TTY=$(port_for_proto 12)  || CTRL_TTY=/dev/ttyUSB1
		[ -c "$CTRL_TTY" ] || CTRL_TTY=$MODEM_TTY
		ok "модемный порт $MODEM_TTY, управляющий $CTRL_TTY (предположительно)"
		ok "привязано интерфейсов: $(ls -d "$USB_DEV":*/ttyUSB* 2>/dev/null | wc -l)"
		# Раскладку печатаем всегда: на незнакомом свистке это единственный способ
		# понять, почему выбран тот порт, а не другой, — особенно когда до головы
		# нет доступа по adb и весь разбор идёт по этому тексту на экране.
		for _i in "$USB_DEV":*; do
			[ -f "$_i/bInterfaceProtocol" ] || continue
			_pr=$(cat "$_i/bInterfaceProtocol" 2>/dev/null)
			_tt=$(ls -d "$_i"/ttyUSB* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')
			say "      $(basename "$_i")  protocol=$_pr  ${_tt:-без ttyUSB}"
		done
	fi

	stage "PPP в ядре"
	[ -c /dev/ppp ] || die "нет /dev/ppp — в ядре не собран CONFIG_PPP" \
		"это уже не лечится модулем, нужен другой способ (NCM/NDIS)"
	ok "/dev/ppp на месте"

	if grep -q '^ppp' /proc/tty/ldiscs 2>/dev/null; then
		skip "line discipline ppp уже зарегистрирована"
	else
		load_module "$KO_PPP" ppp_async ""
		[ "$CHECK_ONLY" = 1 ] || grep -q '^ppp' /proc/tty/ldiscs 2>/dev/null ||
			die "ppp_async загрузился, но ldisc ppp не появилась" "смотри dmesg"
		[ "$CHECK_ONLY" = 1 ] || ok "line discipline ppp зарегистрирована"
	fi

	stage "SIM и регистрация в сети"
	if pidof pppd >/dev/null 2>&1; then
		skip "pppd уже держит порт — AT-опрос пропускаем"
	elif [ "$CHECK_ONLY" = 1 ] && [ ! -c "${CTRL_TTY:-/dev/null}" ]; then
		skip "нет управляющего порта"
	else
		# Ждём ответа, а не спрашиваем один раз. Сразу после modeswitch устройство
		# перечисляется заново: ttyUSB* уже созданы, а прошивка модема ещё не готова
		# разговаривать, и первый AT уходит в пустоту. Единственный вопрос стоил
		# минуты простоя после каждой перезагрузки: заход падал с «не отвечает на AT»,
		# и связь появлялась только со следующей проверкой watchdog'а. Ожидание тут
		# не фиксированное: обычно порт отвечает с первой-второй попытки, а потолок
		# нужен ровно для того, чтобы не висеть вечно на мёртвом модеме.
		# Спрашиваем КАЖДЫЙ ttyUSB устройства, а не только тот, на который указал
		# bInterfaceProtocol. На E173 (12d1:1c05) протокола 12 нет ни у одного
		# интерфейса, догадка даёт ttyUSB1, а он молчит — и весь подъём падал здесь,
		# хотя модем исправен и AT отвечает на соседнем порту.
		_guess=$CTRL_TTY
		_cands=$(at_candidates)
		[ -n "$_cands" ] || die "у устройства нет ни одного ttyUSB" \
			"смотри стадию 6: привязался ли option к интерфейсам"
		_deadline=$(( $(date +%s) + AT_WAIT_SECS ))
		_found=""
		while :; do
			for _cand in $_cands; do
				at "$_cand" "ATE0" 1 >/dev/null 2>&1
				# Регистр ответов приводим к верхнему: на части портов включён iuclc
				# и модем отвечает "ok" вместо "OK".
				case "$(at "$_cand" "AT" 2 | tr 'a-z' 'A-Z')" in
				*OK*) _found=$_cand; break ;;
				esac
			done
			[ -n "$_found" ] && break
			[ "$(date +%s)" -ge "$_deadline" ] && break
			sleep 2
		done
		if [ -n "$_found" ]; then
			CTRL_TTY=$_found
			if [ "$_found" = "$_guess" ]; then
				ok "порт $CTRL_TTY отвечает"
			else
				ok "AT отвечает $CTRL_TTY (догадка $_guess молчит)"
			fi
			# Кладём найденный порт рядом: иконка сети берёт его отсюда и не
			# повторяет тот же перебор со своей стороны.
			[ "$CHECK_ONLY" = 1 ] || echo "$CTRL_TTY" >"$STATE/at-tty" 2>/dev/null
		else
			die "ни один порт не отвечает на AT: $_cands (ждали $AT_WAIT_SECS с)" \
			    "порт мог занять другой процесс, либо модем ещё не готов"
		fi

		_r=$(at "$CTRL_TTY" "AT+CPIN?" 3 | tr 'a-z' 'A-Z')
		case "$_r" in
		*READY*)      ok "SIM готова" ;;
		*"SIM PIN"*)  die "SIM требует PIN" "сними PIN на телефоне или задай его вручную: AT+CPIN=\"1234\"" ;;
		*"SIM PUK"*)  die "SIM заблокирована (PUK)" "разблокируй SIM на телефоне" ;;
		*ERROR*)      die "модем не видит SIM" "проверь, что SIM вставлена и контакты чистые" ;;
		*)            warn "непонятный ответ на AT+CPIN?: $(echo "$_r" | tr '\n' ' ')" ;;
		esac

		# Сигнал и регистрация появляются не мгновенно после включения модема.
		i=0
		REG=""
		while [ $i -lt 30 ]; do
			_r=$(at "$CTRL_TTY" "AT+CREG?" 2)$(at "$CTRL_TTY" "AT+CGREG?" 2)
			case "$_r" in
			*",1"* | *",5"*) REG=1; break ;;
			esac
			sleep 2
			i=$((i + 2))
		done
		if [ -n "$REG" ]; then
			ok "зарегистрирован в сети"
		else
			die "модем не регистрируется в сети (30 с ожидания)" \
				"проверь баланс/активность SIM и уровень сигнала, вынеси антенну"
		fi

		_r=$(at "$CTRL_TTY" "AT+CSQ" 2)
		_csq=$(echo "$_r" | sed -n 's/.*+CSQ: \([0-9]*\),.*/\1/p' | head -1)
		case "$_csq" in
		99 | "") warn "уровень сигнала неизвестен (+CSQ: $_csq)" ;;
		*)
			if [ "$_csq" -lt 8 ] 2>/dev/null; then
				warn "слабый сигнал (+CSQ: $_csq, меньше 8) — связь может рваться"
			else
				ok "сигнал +CSQ: $_csq"
			fi ;;
		esac

		_r=$(at "$CTRL_TTY" "AT+COPS?" 3)
		_op=$(echo "$_r" | sed -n 's/.*+COPS: [0-9]*,[0-9]*,"\([^"]*\)".*/\1/p' | head -1)
		[ -n "$_op" ] && ok "оператор: $_op"
	fi

	stage "дозвон"
	ADDR=$(iface_addr ppp0)
	if [ -n "$ADDR" ]; then
		skip "ppp0 уже поднят: $ADDR"
	elif [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] pppd $MODEM_TTY ... connect $DIAL_SH"
	else
		if pidof pppd >/dev/null 2>&1; then
			# Даём ему шанс: возможно, дозвон идёт прямо сейчас.
			_w=0
			while [ $_w -lt 10 ] && [ -z "$ADDR" ] && pidof pppd >/dev/null 2>&1; do
				sleep 1
				_w=$((_w + 1))
				ADDR=$(iface_addr ppp0)
			done
		fi
		if [ -n "$ADDR" ]; then
			ok "ppp0 поднялся сам: $ADDR"
		elif pidof pppd >/dev/null 2>&1; then
			# Живой pppd без адреса — это зависший pppd (обычно встал на
			# connect-скрипте, когда модем остался в data-режиме). Он держит
			# модемный порт, поэтому просто ждать бессмысленно: снимаем его,
			# иначе ни одна следующая попытка не начнётся.
			warn "pppd запущен, но ppp0 без адреса — снимаю зависший pppd"
			kill -9 $(pidof pppd) 2>/dev/null
			sleep 2
		fi
		if [ -z "$ADDR" ]; then
			# nodefaultroute — принципиально: подмена основного маршрута оборвала бы
			# управляющий adb. Маршрутизацией занимается отдельная стадия ниже.
			_auth=""
			[ -n "$PPP_USER" ] && _auth="user $PPP_USER"
			APN="$APN" WWAN_DIAL="$DIAL" setsid pppd "$MODEM_TTY" 115200 \
				nodetach noauth nodefaultroute noipdefault \
				ipcp-accept-local ipcp-accept-remote novj novjccomp local \
				lcp-echo-interval 30 lcp-echo-failure 4 \
				$_auth logfile "$PPP_LOG" connect "$DIAL_SH" \
				</dev/null >/dev/null 2>&1 &
			say "   pppd запущен на $MODEM_TTY (APN $APN)"
		fi

		i=0
		while [ $i -lt 60 ]; do
			ADDR=$(iface_addr ppp0)
			[ -n "$ADDR" ] && break
			pidof pppd >/dev/null 2>&1 || break
			sleep 1
			i=$((i + 1))
		done

		if [ -z "$ADDR" ]; then
			# Уходим с ошибкой — но не оставляем за собой pppd, который держит
			# модемный порт: следующая попытка должна начинаться с чистого места.
			pidof pppd >/dev/null 2>&1 && kill -9 $(pidof pppd) 2>/dev/null
			say "   последние строки $PPP_LOG:"
			tail -n 12 "$PPP_LOG" 2>/dev/null | tr -d '\r' | while read -r l; do say "      $l"; done
			_t=$(tail -n 40 "$PPP_LOG" 2>/dev/null)
			case "$_t" in
			*"status = 0x2"*)
				die "модем отверг APN" "проверь APN оператора: сейчас '$APN' (WWAN_APN=...)" ;;
			*"status = 0x3"* | *"NO CARRIER"*)
				die "нет ответа CONNECT на дозвон" "модем не зарегистрирован либо номер дозвона не '$DIAL'" ;;
			*"timeout sending"*)
				die "нет ответа по LCP" "скорее всего это не модемный порт; попробуй WWAN_TTY=/dev/ttyUSB2" ;;
			*"authentication failed"* | *"Peer refused"* | *"CHAP authentication failed"*)
				die "оператор требует логин/пароль" "задай WWAN_USER и WWAN_PASS" ;;
			*)
				die "ppp0 не поднялся за 45 с" "разбирайся по $PPP_LOG" ;;
			esac
		fi
		ok "ppp0 поднят: $ADDR"
	fi

	# DNS оператора спрашиваем у самого модема, 8.8.8.8 — запасной вариант.
	DNS=""
	if [ -n "$CTRL_TTY" ] && [ -c "$CTRL_TTY" ] && ! pidof pppd >/dev/null 2>&1; then
		DNS=$(at "$CTRL_TTY" "AT+CGCONTRDP=1" 3 |
			sed -n 's/.*+CGCONTRDP: [^"]*"[^"]*","[^"]*","[^"]*","\([0-9.]*\)".*/\1/p' | head -1)
	fi
	DNS=${DNS:-8.8.8.8}
fi

# ============================================================== ОБЩЕЕ =======
stage "маршруты и проверка связи"

if [ -z "$ADDR" ] && [ "$CHECK_ONLY" = 1 ]; then
	skip "$WAN_IF не поднят"
else
	add_default "$TABLE" 10
	ip rule show 2>/dev/null | grep -q "from $ADDR " || do_it ip rule add from "$ADDR" table "$TABLE"
	ip rule show 2>/dev/null | grep -q "oif $WAN_IF " || do_it ip rule add oif "$WAN_IF" table "$TABLE"
	ok "маршрут по умолчанию для $WAN_IF в таблице $TABLE"

	if [ "$CHECK_ONLY" = 0 ]; then
		if ping -c 2 -W 4 -I "$WAN_IF" 8.8.8.8 >/dev/null 2>&1; then
			ok "связь есть (ping 8.8.8.8 через $WAN_IF)"
		else
			warn "$WAN_IF поднят, но ping 8.8.8.8 не проходит"
			warn "у оператора может быть заблокирован ICMP — проверь curl/nslookup"
		fi
	fi
fi

# ------------------------------------------------- опционально: приложения --
if [ "$DO_SYSTEM" = 1 ]; then
	stage "интернет для приложений Android"

	# Правила вендора 9990-9999 «from all lookup main» идут раньше fwmark-правил,
	# поэтому root/adb-сессиям достаточно default в main.
	_cur=$(ip route show table main 2>/dev/null | grep '^default')
	case "$_cur" in
	*"dev $WAN_IF"*)
		skip "в main уже default через $WAN_IF" ;;
	"")
		add_default main 20
		ok "default через $WAN_IF добавлен в main (metric 20)" ;;
	*)
		warn "в main уже есть чужой default: $_cur"
		warn "не трогаю — убери его вручную, если нужен модем" ;;
	esac

	# У приложений маршрутизация другая: ConnectivityService помечает их сокеты
	# fwmark'ом конкретной сети (netd, per-app default network) и заворачивает
	# в СВОЮ таблицу маршрутизации ("vlan72" для этой сети) — правило main здесь
	# вообще не участвует. Штатный TBOX физически снят, но Android держит его
	# "призрачную" сотовую сеть (единственную с CELLULAR/INTERNET, когда Wi-Fi
	# выключен), и таблица vlan72 указывает default на мёртвый шлюз
	# 192.168.72.1 (постоянная ARP-запись без реального устройства за ней) —
	# трафик приложений туда просто проваливается. Проверено напрямую:
	# `ping -m <fwmark-этой-сети> 8.8.8.8` не проходил до этой правки и проходит
	# после переопределения default в таблице vlan72 на модем.
	_line=$(dumpsys connectivity 2>/dev/null | grep -m1 'type: Tbox')
	[ -n "$_line" ] || _line=$(dumpsys connectivity 2>/dev/null | grep -m1 'Transports: CELLULAR')
	TB_IF=$(echo "$_line" | sed -n 's/.*InterfaceName: \([a-z0-9._-]*\).*/\1/p')
	TB_DNS=$(echo "$_line" | sed -n 's/.*DnsAddresses: \[ *\/\([0-9.]*\).*/\1/p')
	TB_IF=${TB_IF:-vlan72}
	TB_DNS=${TB_DNS:-192.168.72.1}
	TB_SRC=$(iface_addr "$TB_IF")

	if [ -z "$TB_SRC" ]; then
		warn "у $TB_IF нет адреса — эта сеть сейчас не активна, пропускаю"
	elif ip route show table "$TB_IF" 2>/dev/null | grep -q "^default.* dev $WAN_IF"; then
		skip "таблица $TB_IF уже указывает на $WAN_IF"
	else
		add_default "$TB_IF" 5
		ok "таблица $TB_IF: default переключён на $WAN_IF (приложения теперь идут через модем)"
	fi

	# DNS нужен отдельно от правки таблицы выше: сам сервер 192.168.72.1 лежит
	# внутри подсети vlan72/24, для него per-host маршрут (scope link) важнее
	# default и всегда уводит пакет в мёртвый L2 — что бы мы ни клали в default
	# той же таблицы. Поэтому адрес сервера подменяем DNAT'ом на живой, после
	# чего пакет уже выходит из подсети и идёт по (исправленному) default.
	if [ -z "$TB_SRC" ]; then
		: # уже предупредили выше
	elif [ "$TB_DNS" = "$DNS" ]; then
		skip "DNS фантомной сети совпадает с DNS модема — подменять нечего"
	elif dns_answers "$TB_DNS"; then
		skip "DNS $TB_DNS уже отвечает — netfilter не трогаю"
	else
		_stale=$(iptables -w 10 -t nat -S OUTPUT 2>/dev/null | grep "$TB_DNS" | grep -v "to-destination $DNS:53")
		[ -n "$_stale" ] && warn "есть старые правила на $TB_DNS, убери вручную: $_stale"
		for proto in udp tcp; do
			iptables -w 10 -t nat -C OUTPUT -d "$TB_DNS" -p $proto --dport 53 \
				-j DNAT --to-destination "$DNS:53" 2>/dev/null ||
				do_it iptables -w 10 -t nat -A OUTPUT -d "$TB_DNS" -p $proto --dport 53 \
					-j DNAT --to-destination "$DNS:53"
		done
		iptables -w 10 -t nat -C POSTROUTING -s "$TB_SRC" -o "$WAN_IF" -j MASQUERADE 2>/dev/null ||
			do_it iptables -w 10 -t nat -A POSTROUTING -s "$TB_SRC" -o "$WAN_IF" -j MASQUERADE
		ok "DNS $TB_DNS ($TB_IF) перенаправлен на $DNS через $WAN_IF"
	fi

	# Признак, который реально видят приложения (не заглядывая внутрь netd):
	# ConnectivityService перепроверяет валидацию не мгновенно — сразу после
	# этой стадии сеть ещё может числиться невалидированной.
	if [ "$CHECK_ONLY" = 0 ]; then
		_val=$(dumpsys connectivity 2>/dev/null | grep -m1 'type: Tbox' | grep -o 'everValidated{[a-z]*}')
		case "$_val" in
		*true*) ok "сеть приложений (Tbox) уже провалидирована" ;;
		*) warn "сеть приложений (Tbox) ещё не провалидирована — Android перепроверяет её не сразу, подожди и посмотри снова: dumpsys connectivity | grep -A1 'type: Tbox'" ;;
		esac
	fi
fi

# ------------------------------------------------------------------ итог ----
say ""
say "== итог"
say "   тип:       $MODE"
say "   $WAN_IF:      ${ADDR:-не поднят}"
say "   маршрут:   $(ip route show table "$TABLE" 2>/dev/null | head -1)"
if [ "$CHECK_ONLY" = 0 ] && [ -n "$ADDR" ]; then
	if timeout 10 ping -c 1 -W 5 -I "$WAN_IF" 8.8.8.8 >/dev/null 2>&1; then
		say "   интернет:  есть"
	else
		say "   интернет:  ping не проходит (см. предупреждения выше)"
	fi
fi
say "   лог:       $LOG"

# Состояние для wwan-boot.sh: какой интерфейс сторожить в watchdog-цикле.
if [ "$CHECK_ONLY" = 0 ] && [ -n "$ADDR" ]; then
	mkdir -p "$STATE" 2>/dev/null
	echo "$WAN_IF" >"$STATE/wan-iface" 2>/dev/null
	# Иконка сотовой сети в статус-баре: показать сигнал этого модема вместо крестика.
	# Отдельный отцепленный процесс, к подъёму модема отношения не имеет — поэтому и
	# запускается последним, молча и без права уронить результат (см. tbox-icon.sh auto
	# и docs/status-icon.md).
	[ -x "$DIR/tbox-icon.sh" ] && sh "$DIR/tbox-icon.sh" auto 2>&1 | sed 's/^/   /'
fi
exit 0
