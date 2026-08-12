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
#
# Под капотом — tboxwire.jar: он притворяется блоком TBOX, которого на стенде нет, и шлёт
# голове по SOME/IP цифры нашего модема. Подробности — docs/status-icon.md.
#
# ПОРЯДОК АРГУМЕНТОВ app_process. Каталог приложения идёт ПЕРЕД опциями:
#     app_process /system/bin --nice-name=tboxwire TboxWire ...
# Если написать наоборот (`app_process --nice-name=... /system/bin TboxWire`), парсер
# app_main.cpp примет "/system/bin" за имя класса и процесс молча упадёт с кодом 1,
# ничего не написав ни в stdout, ни в logcat. На этом уже потеряли полчаса.
#
# АЛИАС .37. Пакеты должны идти не с 192.168.62.4 — это адрес самой головы. Поэтому на
# vlan62 вешается secondary-адрес 192.168.62.37 (в permanent-ARP QNX на vlan62 значатся
# .1, .5, .10, .14, .37; .5 — QNX, .4 — Android; физического TBOX на стенде нет).
# Алиас переживает только до перезагрузки, поэтому вешаем его при каждом старте.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
STATE=${WWAN_STATE:-$DIR/state}
JAR=${TBOX_JAR:-$DIR/tboxwire.jar}
SRC_IP=${TBOX_SRC:-192.168.62.37}
IFACE=${TBOX_IFACE:-vlan62}
LOG=$STATE/tbox.log
PIDFILE=$STATE/tbox.pid
SWITCH=$STATE/icon

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

add_alias() {
	if ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q " $SRC_IP/"; then
		return 0
	fi
	echo "== вешаем $SRC_IP на $IFACE"
	ip addr add "$SRC_IP/24" dev "$IFACE" label "$IFACE:tbox" || {
		echo "не смог добавить адрес — нужен root" >&2
		exit 1
	}
}

# Один и тот же запуск и для start, и для fake/signal: разница только в аргументах.
java_run() {
	exec env CLASSPATH="$JAR" app_process /system/bin --nice-name=tboxwire TboxWire \
		--src "$SRC_IP" --iface "$IFACE" --wwan-dir "$DIR" "$@"
}

case "${1:-status}" in
start)
	shift
	need_jar
	PID=$(running_pid)
	[ -n "$PID" ] && { echo "уже работает, pid $PID (остановить: $0 stop)"; exit 0; }
	add_alias
	# setsid + закрытый stdin: процесс должен пережить обрыв adb-сессии, из которой
	# его запустили. Именно так приложение стартует и wwan-boot.sh.
	setsid sh -c "CLASSPATH=$JAR exec app_process /system/bin --nice-name=tboxwire \
		TboxWire --src $SRC_IP --iface $IFACE --wwan-dir $DIR $*" \
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
	echo "алиас:    $(ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep " $SRC_IP/" |
		sed 's/  */ /g' || echo "нет $SRC_IP на $IFACE")"
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
	add_alias
	echo "показываем фиксированные $N палок, Ctrl-C чтобы прекратить"
	java_run --strength "$N"
	;;

-h | --help | help)
	sed -n '2,12p' "$0"
	;;

*)
	echo "неизвестная команда: $1 (см. --help)" >&2
	exit 64
	;;
esac
