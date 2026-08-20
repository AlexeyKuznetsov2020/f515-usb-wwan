#!/system/bin/sh
# scripts/sms.sh — чтение и управление SMS через AT-порт USB-модема (PPP / AT-режим).
set -e

ACTION="${1:-list}"
TARGET_ID="$2"

# 1. Поиск свободного AT-порта
find_at_port() {
	if [ -n "$WWAN_CTRL_TTY" ] && [ -c "$WWAN_CTRL_TTY" ]; then
		echo "$WWAN_CTRL_TTY"
		return 0
	fi

	PPP_TTY=""
	if pgrep pppd >/dev/null 2>&1; then
		PPP_TTY=$(ps -ef 2>/dev/null | grep pppd | grep -o 'ttyUSB[0-9]*' | head -1)
		[ -n "$PPP_TTY" ] && PPP_TTY="/dev/$PPP_TTY"
	fi

	for t in /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB0; do
		[ -c "$t" ] || continue
		[ "$t" = "$PPP_TTY" ] && continue
		# Быстрый опрос AT
		stty -F "$t" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1 || true
		RESP=$(timeout --foreground 2 sh -c '
			exec 3<>"$1" || exit 1
			printf "AT\r" >&3
			cat <&3 | tr -d "\r"
		' sh "$t" 2>/dev/null || true)
		if echo "$RESP" | grep -q "OK"; then
			echo "$t"
			return 0
		fi
	done

	for t in /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
		[ -c "$t" ] && [ "$t" != "$PPP_TTY" ] && echo "$t" && return 0
	done

	return 1
}

PORT=$(find_at_port)
if [ -z "$PORT" ] || [ ! -c "$PORT" ]; then
	echo "ERROR: Не найден свободный AT-порт модема (ttyUSB)"
	exit 1
fi

stty -F "$PORT" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1 || true

case "$ACTION" in
list)
	timeout --foreground 10 sh -c '
		P=$1
		exec 3<>"$P" || exit 1
		timeout --foreground 1 cat <&3 >/dev/null 2>&1 || true

		run_cmd() {
			printf "%s\r" "$1" >&3
			while read -t 1 -r line <&3; do
				echo "$line"
				case "$line" in
					*OK*|*ERROR*|*+CMS\ ERROR*) break ;;
				esac
			done
		}

		run_cmd "AT"
		run_cmd "AT+CPMS=\"SM\",\"SM\",\"SM\""
		run_cmd "AT+CMGF=0"
		run_cmd "AT+CMGL=4"
		run_cmd "AT+CPMS=\"ME\",\"ME\",\"ME\""
		run_cmd "AT+CMGF=0"
		run_cmd "AT+CMGL=4"
	' sh "$PORT"
	;;

delete)
	if [ -z "$TARGET_ID" ]; then
		echo "ERROR: Укажите индекс SMS для удаления"
		exit 1
	fi
	timeout --foreground 5 sh -c '
		P=$1
		ID=$2
		exec 3<>"$P" || exit 1
		printf "AT+CMGD=%s\r" "$ID" >&3
		while read -t 1 -r line <&3; do
			echo "$line"
			case "$line" in
				*OK*|*ERROR*|*+CMS\ ERROR*) break ;;
			esac
		done
	' sh "$PORT" "$TARGET_ID"
	;;

delete_all)
	timeout --foreground 6 sh -c '
		P=$1
		exec 3<>"$P" || exit 1
		run_cmd() {
			printf "%s\r" "$1" >&3
			while read -t 1 -r line <&3; do
				echo "$line"
				case "$line" in
					*OK*|*ERROR*|*+CMS\ ERROR*) break ;;
				esac
			done
		}
		run_cmd "AT+CPMS=\"SM\",\"SM\",\"SM\""
		run_cmd "AT+CMGD=1,4"
		run_cmd "AT+CPMS=\"ME\",\"ME\",\"ME\""
		run_cmd "AT+CMGD=1,4"
	' sh "$PORT"
	;;

*)
	echo "Unknown action: $ACTION"
	exit 1
	;;
esac
