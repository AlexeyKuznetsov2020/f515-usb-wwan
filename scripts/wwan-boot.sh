#!/system/bin/sh
# wwan-boot.sh — то, что запускается САМО после перезагрузки головы: поднимает
# модем и дальше сторожит связь. Запускает его приложение (BootService) через
# локальный adb, отцепленным процессом (setsid), поэтому обрыв adb-сессии его не
# убивает.
#
#   wwan-boot.sh             автозапуск: защита -> подъём -> watchdog-цикл
#   wwan-boot.sh --now       то же, но без задержки после загрузки
#   wwan-boot.sh --status    состояние в вида key=value (читает приложение)
#   wwan-boot.sh --reset     снять защиту и снова разрешить автозапуск
#   wwan-boot.sh --disable   выключить автозапуск (создать файл-выключатель)
#   wwan-boot.sh --stop      остановить watchdog (модем не трогает)
#
# ЗАЩИТА ОТ БУТЛУПА — тут главная мысль всего файла:
#
#   1. Счётчик `attempts` увеличивается ПЕРЕД работой и обнуляется СРАЗУ ПОСЛЕ
#      того, как wwan-up.sh вернул управление — неважно, успешно или с ошибкой.
#      То есть счётчик считает не «неудачные подъёмы», а «заходы, из которых мы
#      не вернулись»: если голова умерла посреди работы и перезагрузилась,
#      счётчик так и остался увеличенным. MAX_ATTEMPTS таких подряд — и
#      автозапуск выключает сам себя. Обычная ошибка («модем не воткнут»)
#      счётчик не копит и в безопасный режим не уводит.
#   2. Маркер insmod-inflight (его ставит wwan-up.sh --boot вокруг insmod, с
#      sync) — точная подпись «упали именно на загрузке модуля ядра».
#      Единственная операция во всём проекте, способная уронить ядро целиком.
#      Остался маркер — автозапуск выключается сразу, не дожидаясь счётчика.
#   3. Файл-выключатель `disabled` с причиной внутри: пока он есть, автозапуск
#      не делает ничего. Снимается только вручную (--reset) или из приложения.
#   4. Задержка перед подъёмом: система после BOOT_COMPLETED ещё догружается,
#      лезть в USB/ядро в этот момент незачем.

DIR=$(cd "$(dirname "$0")" && pwd)
STATE=${WWAN_STATE:-$DIR/state}
LOG=$STATE/boot.log
UP=$DIR/wwan-up.sh

ATTEMPTS=$STATE/attempts
DISABLED=$STATE/disabled
INFLIGHT=$STATE/insmod-inflight
LAST_OK=$STATE/last-ok
WAN_FILE=$STATE/wan-iface
PIDFILE=$STATE/watchdog.pid
RESTARTS=$STATE/restarts

MAX_ATTEMPTS=${WWAN_MAX_ATTEMPTS:-3}
# Пауза перед первым заходом. Была 45 с «на всякий случай», но ждать тут нечего:
# приложение и так стартует нас только после того, как дождалось adbd, а всё
# остальное (модуль, порты, регистрация) wwan-up.sh проверяет сам и с ретраями.
# Пять секунд оставлены как фора планировщику: сразу после BOOT_COMPLETED голова
# занята собой, и торопиться в эту секунду смысла нет.
BOOT_DELAY=${WWAN_BOOT_DELAY:-5}
WATCH_INTERVAL=${WWAN_WATCH_INTERVAL:-60}
# Сколько раз подряд пробовать поднять модем внутри ОДНОГО захода и с какой паузой.
# Первый заход после перезагрузки часто падает не потому, что что-то сломано, а
# потому, что модем только что перещёлкнули modeswitch'ем: порты уже есть, а AT в
# них ещё не отвечает. Раньше это стоило минуты простоя — заход сдавался, и связь
# появлялась только со следующей проверкой watchdog'а. Ретраи живут внутри bring_up
# и в счётчик перезапусков за час не идут: голова между ними не перезагружается.
BRINGUP_RETRIES=${WWAN_BRINGUP_RETRIES:-3}
BRINGUP_RETRY_DELAY=${WWAN_BRINGUP_RETRY_DELAY:-5}
# Больше стольких перезапусков за час — считаем, что чиним не то, и уходим спать
# надолго, чтобы не долбить модем и не жечь трафик впустую.
MAX_RESTARTS_PER_HOUR=${WWAN_MAX_RESTARTS:-4}
COOLDOWN=${WWAN_COOLDOWN:-1800}

mkdir -p "$STATE" 2>/dev/null

log() {
	echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null
	echo "$*"
}

# Усечение логов: logrotate на голове нет, а все файлы только дописываются.
# Перевалил за LOG_MAX — оставляем последнюю половину. Пишем в ТОТ ЖЕ inode
# (`cat`, а не `mv`): tbox.log держит открытым живой tboxwire, и подмена файла
# оставила бы его писать в отвязанный inode — место на флеше не освободилось бы,
# а видимый файл замер бы навсегда.
LOG_MAX=${WWAN_LOG_MAX:-5242880}
log_trim() {
	for _lt_f in "$@"; do
		[ -f "$_lt_f" ] || continue
		_lt_sz=$(stat -c %s "$_lt_f" 2>/dev/null) || continue
		[ "$_lt_sz" -gt "$LOG_MAX" ] 2>/dev/null || continue
		log "усекаю $_lt_f: $_lt_sz байт больше потолка $LOG_MAX"
		tail -c $((LOG_MAX / 2)) "$_lt_f" >"$_lt_f.trim" 2>/dev/null &&
			cat "$_lt_f.trim" >"$_lt_f" 2>/dev/null
		rm -f "$_lt_f.trim" 2>/dev/null
	done
}

# Все логи проекта в одном месте: сторож — единственный, кто работает постоянно,
# и следить за размерами удобнее ему. ppp.log сюда же, хотя пишет его pppd.
LOG_FILES="$LOG $STATE/boot-stdout.log $STATE/tbox.log /data/local/tmp/wwan.log /data/local/tmp/ppp.log"

disable() {
	echo "$(date '+%F %T') $1" >"$DISABLED"
	sync
	log "АВТОЗАПУСК ВЫКЛЮЧЕН: $1"
	log "включить обратно: sh $0 --reset (или кнопкой в приложении)"
}

read_num() { n=$(cat "$1" 2>/dev/null); case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac; }

wan_iface() { cat "$WAN_FILE" 2>/dev/null; }

# Живой ли записанный watchdog: печатает его pid или ничего. Проверка cmdline
# обязательна — pidfile переживает перезагрузку, и номер вполне может оказаться
# занят посторонним процессом (см. подробности у проверки экземпляра ниже).
# Для --stop это ещё и вопрос безопасности: по голому `kill -0` мы бы отстрелили
# чужой процесс.
watchdog_pid() {
	_w=$(cat "$PIDFILE" 2>/dev/null)
	[ -n "$_w" ] || return 1
	kill -0 "$_w" 2>/dev/null || return 1
	grep -qs wwan-boot /proc/$_w/cmdline || return 1
	echo "$_w"
}

iface_addr() { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

# ------------------------------------------------------------ команды UI ----
case "$1" in
--status)
	echo "disabled=$([ -f "$DISABLED" ] && echo 1 || echo 0)"
	echo "disabled_reason=$(cat "$DISABLED" 2>/dev/null)"
	echo "attempts=$(read_num "$ATTEMPTS")"
	echo "max_attempts=$MAX_ATTEMPTS"
	echo "inflight=$([ -f "$INFLIGHT" ] && echo 1 || echo 0)"
	echo "last_ok=$(cat "$LAST_OK" 2>/dev/null)"
	_p=$(watchdog_pid)
	if [ -n "$_p" ]; then
		echo "watchdog=1 pid=$_p"
	else
		echo "watchdog=0"
	fi
	_if=$(wan_iface)
	echo "wan_iface=$_if"
	echo "wan_addr=$([ -n "$_if" ] && iface_addr "$_if")"
	exit 0 ;;
--reset)
	rm -f "$DISABLED" "$INFLIGHT" "$RESTARTS"
	echo 0 >"$ATTEMPTS"
	sync
	log "защита сброшена вручную, автозапуск снова разрешён"
	exit 0 ;;
--disable)
	disable "выключено вручную"
	exit 0 ;;
--stop)
	_p=$(watchdog_pid)
	if [ -n "$_p" ]; then
		kill "$_p" && log "watchdog остановлен (pid $_p)"
	else
		log "watchdog не запущен"
	fi
	rm -f "$PIDFILE"
	exit 0 ;;
esac

NOW_MODE=0
[ "$1" = "--now" ] && NOW_MODE=1

# ------------------------------------------------------------- проверки -----
log "=================================================================="
log "wwan-boot: старт (uptime $(cut -d. -f1 /proc/uptime 2>/dev/null) с, режим now=$NOW_MODE)"

if [ -f "$DISABLED" ]; then
	log "автозапуск выключен: $(cat "$DISABLED" 2>/dev/null)"
	log "снять: sh $0 --reset"
	exit 0
fi

if [ -f "$INFLIGHT" ]; then
	# Маркер должен был сняться сразу после insmod. Раз он тут — прошлый заход
	# оборвался на загрузке модуля, то есть голова упала именно из-за нас.
	disable "прошлый заход оборвался на insmod ($(cat "$INFLIGHT" 2>/dev/null)) — похоже, голова упала из-за загрузки модуля"
	rm -f "$INFLIGHT"
	sync
	exit 0
fi

A=$(read_num "$ATTEMPTS")
if [ "$A" -ge "$MAX_ATTEMPTS" ]; then
	disable "$A подряд заходов не дошли до конца (порог $MAX_ATTEMPTS) — похоже на цикл перезагрузок"
	exit 0
fi

# Уже работает другой экземпляр — второй watchdog не нужен.
#
# Одного `kill -0` тут мало, и это не теория: pidfile лежит в /data и переживает
# перезагрузку, а номера pid на раннем старте раздаются почти детерминированно.
# 2026-08-11 после двух ребутов подряд в pidfile оставался pid 5681 от прошлой
# загрузки, на 45-й секунде аптайма этот номер был занят посторонним процессом —
# и автозапуск оба раза выходил с «уже работает экземпляр», модем не поднимался
# вообще, хотя приложение честно рапортовало, что автозапуск включён. Поэтому
# проверяем не «номер занят», а «занят именно нами»: cmdline процесса должен
# содержать имя этого скрипта.
P=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$P" ] && [ "$P" != "$$" ] && kill -0 "$P" 2>/dev/null &&
   grep -qs wwan-boot /proc/$P/cmdline; then
	log "уже работает экземпляр (pid $P) — выхожу"
	exit 0
fi
[ -n "$P" ] && [ "$P" != "$$" ] && log "pidfile от прошлой загрузки (pid $P мёртв или чужой) — забираю себе"

# Занимаем pidfile СРАЗУ, до задержки и до подъёма. Иначе после ребута
# получается гонка: BOOT_COMPLETED прилетает следом за LOCKED_BOOT_COMPLETED,
# приложение запускает нас дважды с разницей в пару секунд, обе копии видят
# пустой pidfile, обе поднимают модем и обе остаются сторожить. Проверено на
# стенде: после первого же ребута работали два экземпляра.
echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"; exit 0' TERM INT

[ -x "$UP" ] || chmod 755 "$UP" 2>/dev/null
[ -f "$UP" ] || { log "нет $UP — нечего запускать"; rm -f "$PIDFILE"; exit 1; }

if [ "$NOW_MODE" = 0 ] && [ "$BOOT_DELAY" -gt 0 ]; then
	log "жду $BOOT_DELAY с, пока система догрузится"
	sleep "$BOOT_DELAY"
fi

# -------------------------------------------------------------- подъём ------
bring_up() {
	_a=$(read_num "$ATTEMPTS")
	echo $((_a + 1)) >"$ATTEMPTS"
	sync
	_try=1
	while :; do
		log "--- wwan-up.sh --system --boot (заход $((_a + 1)), попытка $_try/$BRINGUP_RETRIES) ---"
		# Вывод wwan-up.sh в boot.log НЕ перенаправляем: он и так пишет каждую
		# свою строку в wwan.log со своими отметками времени, и копия здесь
		# означала бы вторую запись тех же двух-трёх килобайт на флеш за заход.
		# Наружу вывод всё же идёт: запущенному руками он нужен на экране, а у
		# отцепленного сторожа stdout уводит в /dev/null само приложение.
		sh "$UP" --system --boot
		_rc=$?
		# Управление вернулось — значит голова пережила заход, что бы там ни было
		# с модемом. Именно это и обнуляет счётчик (см. шапку файла).
		echo 0 >"$ATTEMPTS"
		sync
		_if=$(wan_iface)
		_ad=$([ -n "$_if" ] && iface_addr "$_if")
		if [ -n "$_ad" ]; then
			date '+%F %T' >"$LAST_OK"
			log "подъём ок: $_if $_ad (rc=$_rc)"
			return 0
		fi
		[ "$_try" -ge "$BRINGUP_RETRIES" ] && break
		log "попытка $_try не удалась (rc=$_rc) — повтор через $BRINGUP_RETRY_DELAY с"
		sleep "$BRINGUP_RETRY_DELAY"
		_try=$((_try + 1))
	done
	log "подъём не удался (rc=$_rc), подробности в wwan.log"
	return 1
}

bring_up

# ------------------------------------------------------------ watchdog ------
# pidfile уже занят выше, перед задержкой — здесь заново его писать не нужно.
log "watchdog: проверка каждые $WATCH_INTERVAL с (не больше $MAX_RESTARTS_PER_HOUR перезапусков в час)"

soft_fails=0
while :; do
	sleep "$WATCH_INTERVAL"

	if [ -f "$DISABLED" ]; then
		log "watchdog: появился файл-выключатель — выхожу"
		break
	fi

	# Иконка сотовой сети живёт отдельным процессом и к связи отношения не имеет:
	# проверяем её тут же, но молча и не влияя ни на что (см. docs/status-icon.md).
	[ -x "$DIR/tbox-icon.sh" ] && sh "$DIR/tbox-icon.sh" auto >/dev/null 2>&1

	log_trim $LOG_FILES

	IF=$(wan_iface)
	if [ -z "$IF" ]; then
		log "watchdog: интерфейс неизвестен (подъём ни разу не удался) — пробую поднять"
		bring_up
		continue
	fi

	ADDR=$(iface_addr "$IF")
	HARD=0
	if [ -z "$ADDR" ]; then
		HARD=1
		REASON="у $IF нет адреса"
	elif [ "$IF" = ppp0 ] && ! pidof pppd >/dev/null 2>&1; then
		HARD=1
		REASON="ppp0 есть, а pppd не запущен"
	fi

	if [ "$HARD" = 0 ]; then
		# Адрес на месте — ещё не значит, что связь живая. Но и ронять сессию
		# из-за одного потерянного пинга нельзя: у части операторов ICMP режется,
		# поэтому реагируем только на три неудачи подряд.
		if timeout 15 ping -c 2 -W 5 -I "$IF" 8.8.8.8 >/dev/null 2>&1; then
			soft_fails=0
			continue
		fi
		soft_fails=$((soft_fails + 1))
		log "watchdog: $IF $ADDR есть, но пинг не проходит ($soft_fails/3)"
		[ "$soft_fails" -lt 3 ] && continue
		REASON="три проверки связи подряд не прошли"
	fi

	# Ограничитель частоты: считаем отметки перезапусков за последний час.
	NOW=$(date +%s)
	touch "$RESTARTS" 2>/dev/null
	RECENT=$(awk -v now="$NOW" 'now - $1 < 3600' "$RESTARTS" 2>/dev/null)
	CNT=$(echo "$RECENT" | grep -c '[0-9]')
	if [ "$CNT" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
		log "watchdog: уже $CNT перезапусков за час ($REASON) — пауза $COOLDOWN с"
		sleep "$COOLDOWN"
		: >"$RESTARTS"
		soft_fails=0
		continue
	fi
	{ echo "$RECENT"; echo "$NOW"; } | grep '[0-9]' >"$RESTARTS.new" 2>/dev/null
	mv "$RESTARTS.new" "$RESTARTS" 2>/dev/null

	log "watchdog: связь потеряна ($REASON) — поднимаю заново"
	soft_fails=0
	bring_up
done

rm -f "$PIDFILE"
exit 0
