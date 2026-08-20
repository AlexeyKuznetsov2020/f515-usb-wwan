#!/system/bin/sh
# tbox-icon.sh — иконка сотовой сети в статус-баре головы показывает сигнал USB-модема.
#
#   tbox-icon.sh start [аргументы TboxWire]   запустить (отцепленным процессом)
#   tbox-icon.sh stop                         остановить
#   tbox-icon.sh auto                         запустить, если пользователь не отключил
#   tbox-icon.sh status                       работает или нет + последние строки лога
#   tbox-icon.sh signal                       разовый опрос модема, ничего не запуская
#   tbox-icon.sh fake N                       показать фиксированные N палок (проверка)
#
# Выключатель — файл state/icon со словом on/off внутри (а не «есть файл/нет файла»:
# в этом проекте запрещено удалять что-либо, а выключатель должен сниматься). Пока там
# off, `auto` молчит, и модем поднимается без всякой иконки. Файла нет — считаем on.
# `auto` стартует, пока в state/icon явно не написано off.
#
# Под капотом — tboxwire.jar: он опрашивает модем и пишет уровень сигнала в файл
# $SIGNAL_BRIDGE, откуда его читает Frida-твик iSpaceToolbox «Статус сети» и рисует иконку.
# Эмуляции блока TBOX по SOME/IP в этом форке нет: на нашей машине TBOX не заявлен
# (config tbox=0), штатной иконки в панели не существует, и оферить было некому.
# Подробности — docs/status-icon.md.
#
# ПОРЯДОК АРГУМЕНТОВ app_process. Каталог приложения идёт ПЕРЕД опциями:
#     app_process /system/bin --nice-name=tboxwire TboxWire ...
# Если написать наоборот (`app_process --nice-name=... /system/bin TboxWire`), парсер
# app_main.cpp примет "/system/bin" за имя класса и процесс молча упадёт с кодом 1,
# ничего не написав ни в stdout, ни в logcat. На этом уже потеряли полчаса.
#
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
STATE=${WWAN_STATE:-$DIR/state}
JAR=${TBOX_JAR:-$DIR/tboxwire.jar}
LOG=$STATE/tbox.log
PIDFILE=$STATE/tbox.pid
SWITCH=$STATE/icon
# Файл сигнала: его читает Frida-твик iSpaceToolbox «Статус сети» и рисует иконку в
# статус-баре. tmpfs (/dev), НЕ /data/local/tmp — переписывается каждые несколько секунд,
# а /data/local/tmp на этой голове флеш. Формат — см. TboxWire.writeSignalFile / твик.
SIGNAL_BRIDGE=${TBOX_SIGNAL_FILE:-/dev/network-status-signal}

mkdir -p "$STATE" 2>/dev/null

enabled() { [ "$(cat "$SWITCH" 2>/dev/null)" != off ]; }

running_pid() {
	# pidof надёжнее pidfile: имя процесса задаёт --nice-name, и переживает оно всё.
	pidof tboxwire 2>/dev/null | awk '{print $1}'
}

need_jar() {
	[ -f "$JAR" ] || {
		echo "нет $JAR — разложи содержимое tbox/prebuilt/ рядом со скриптами" >&2
		exit 1
	}
}

# Один и тот же запуск и для start, и для fake/signal: разница только в аргументах.
java_run() {
	exec env CLASSPATH="$JAR" app_process /system/bin --nice-name=tboxwire TboxWire \
		--wwan-dir "$DIR" "$@"
}

case "${1:-status}" in
start)
	shift
	need_jar
	PID=$(running_pid)
	[ -n "$PID" ] && { echo "уже работает, pid $PID (остановить: $0 stop)"; exit 0; }
	# Сигнал всегда пишется в файл: его читает твик iSpaceToolbox и рисует иконку.
	# Запись в tmpfs раз в 5 с не стоит ничего, а лишней быть не может — если твик не
	# установлен, файл просто никто не читает.
	# chmod отдельной командой, а не через `&&`: файл мог остаться с прошлого запуска
	# (в /dev, но с правами 600 от того, кто создал его первым) — тогда `: >` его только
	# усечёт, а права надо всё равно поправить, иначе SystemUI молча не прочитает.
	: >"$SIGNAL_BRIDGE" 2>/dev/null
	chmod 666 "$SIGNAL_BRIDGE" 2>/dev/null
	# Кавычки внутри строки для `sh -c`: путь задаётся снаружи ($TBOX_SIGNAL_FILE).
	EXTRA="--signal-file '$SIGNAL_BRIDGE'"
	echo "сигнал пишется в $SIGNAL_BRIDGE"
	echo "иконку рисует твик iSpaceToolbox «Статус сети» (без него файл просто никто не читает)"
	# Логи только дописываются, logrotate на голове нет. Старт — самая удобная
	# точка усечения: файл ещё никем не открыт, а дальше в него будет писать
	# живой процесс (в цикле за размером следит watchdog в wwan-boot.sh).
	LOG_MAX=${WWAN_LOG_MAX:-5242880}
	_sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
	if [ "$_sz" -gt "$LOG_MAX" ] 2>/dev/null; then
		tail -c $((LOG_MAX / 2)) "$LOG" >"$LOG.trim" 2>/dev/null &&
			cat "$LOG.trim" >"$LOG" 2>/dev/null
		rm -f "$LOG.trim" 2>/dev/null
	fi
	# setsid + закрытый stdin: процесс должен пережить обрыв adb-сессии, из которой
	# его запустили. Именно так приложение стартует и wwan-boot.sh.
	setsid sh -c "CLASSPATH=$JAR exec app_process /system/bin --nice-name=tboxwire \
		TboxWire --wwan-dir $DIR $EXTRA $*" \
		</dev/null >>"$LOG" 2>&1 &
	i=0
	while [ $i -lt 10 ]; do
		PID=$(running_pid)
		[ -n "$PID" ] && break
		sleep 1
		i=$((i + 1))
	done
	if [ -z "$PID" ]; then
		echo "не поднялся — смотри $LOG" >&2
		tail -20 "$LOG" 2>/dev/null
		exit 1
	fi
	echo "$PID" >"$PIDFILE"
	echo on >"$SWITCH"
	echo "запущен, pid $PID, лог $LOG"
	;;

auto)
	# Вызывается из wwan-up.sh и из watchdog'а wwan-boot.sh, поэтому молчаливая и
	# ничего не ломает: выключено — вышли, уже работает — вышли.
	enabled || { echo "иконка выключена (state/icon=off)"; exit 0; }
	[ -f "$JAR" ] || { echo "иконка: нет $JAR, пропускаем"; exit 0; }
	[ -n "$(running_pid)" ] && exit 0
	# Единственный выключатель — state/icon=off (проверен `enabled` выше).
	sh "$0" start >/dev/null 2>&1 || echo "иконка: запустить не вышло, см. $LOG"
	;;

stop)
	PID=$(running_pid)
	if [ -z "$PID" ]; then
		echo "не запущен"
	else
		kill "$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null
		echo "остановлен (pid $PID)"
	fi
	# Пидфайл не удаляем (в проекте запрет на удаление), просто обнуляем.
	: >"$PIDFILE" 2>/dev/null
	# И запоминаем, что иконку выключили руками: иначе её снова поднимет `auto`
	# из wwan-up.sh или из watchdog'а.
	echo off >"$SWITCH"
	# Алиас $SRC_IP не снимаем: он никому не мешает и сам исчезнет при ребуте.
	;;

status)
	PID=$(running_pid)
	if [ -n "$PID" ]; then
		echo "tboxwire: работает, pid $PID"
	else
		echo "tboxwire: не запущен"
	fi
	echo "running=$([ -n "$PID" ] && echo 1 || echo 0)"
	echo "enabled=$(enabled && echo 1 || echo 0)"
	# Поднимет ли иконку `auto` сам после подъёма модема: всегда, пока не выключена
	# явно (state/icon=off).
	if enabled; then echo "autostart=1"; else echo "autostart=0"; fi
	echo "файл:     $(ls -l "$SIGNAL_BRIDGE" 2>/dev/null | sed 's/  */ /g' ||
		echo "нет $SIGNAL_BRIDGE (иконка не запускалась)")"
	echo "сигнал:   $(cat "$SIGNAL_BRIDGE" 2>/dev/null || echo "—")"
	echo "WAN:      $(cat "$STATE/wan-iface" 2>/dev/null || echo "неизвестен (модем не поднимали)")"
	# Пока тут живой pid wwan-up.sh, иконка вместо крестика гоняет палки по кругу.
	_b=$(cat "$STATE/busy" 2>/dev/null)
	_bp=${_b%% *}
	if [ -n "${_bp:-}" ] && grep -qs wwan-up "/proc/$_bp/cmdline" 2>/dev/null; then
		echo "подъём:   идёт — ${_b#* } (pid $_bp), палки анимируются"
	else
		echo "подъём:   не идёт${_b:+ (последняя стадия: ${_b#* })}"
	fi
	[ -f "$LOG" ] && { echo "-- последние строки $LOG:"; tail -8 "$LOG"; }
	;;

signal)
	need_jar
	java_run --signal
	;;

fake)
	shift
	N=${1:-4}
	need_jar
	echo "показываем фиксированные $N палок, Ctrl-C чтобы прекратить"
	# Файл-мост нужен и здесь: на машине без штатной иконки это единственный
	# способ увидеть проверочные палки — рисует их твик, а не панель.
	: >"$SIGNAL_BRIDGE" 2>/dev/null
	chmod 666 "$SIGNAL_BRIDGE" 2>/dev/null
	java_run --signal-file "$SIGNAL_BRIDGE" --strength "$N"
	;;

-h | --help | help)
	sed -n '2,13p' "$0"
	;;

*)
	echo "неизвестная команда: $1 (см. --help)" >&2
	exit 64
	;;
esac
