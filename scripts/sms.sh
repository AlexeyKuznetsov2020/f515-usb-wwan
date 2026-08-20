#!/system/bin/sh
# scripts/sms.sh — чтение и управление SMS через AT-порт USB-модема (PPP / AT-режим).
# Использование:
#   sms.sh list        — прочитать все SMS (выводит сырой PDU/Text ответ модема)
#   sms.sh delete <id> — удалить SMS по индексу
#   sms.sh delete_all  — удалить все SMS из памяти

ACTION="${1:-list}"
TARGET_ID="$2"

# 1. Поиск свободного AT-порта
find_at_port() {
	# Если задан вручную
	if [ -n "$WWAN_CTRL_TTY" ] && [ -c "$WWAN_CTRL_TTY" ]; then
		echo "$WWAN_CTRL_TTY"
		return 0
	fi

	# Проверяем, какой порт занят pppd (если pppd запущен)
	PPP_TTY=""
	if pgrep pppd >/dev/null 2>&1; then
		# Ищем аргумент ttyUSB в строке запуска pppd
		PPP_TTY=$(ps -ef 2>/dev/null | grep pppd | grep -o 'ttyUSB[0-9]*' | head -1)
		[ -n "$PPP_TTY" ] && PPP_TTY="/dev/$PPP_TTY"
	fi

	# Перебираем кандидаты ttyUSB (предпочитая ttyUSB1, ttyUSB2, ttyUSB3)
	CANDIDATES=""
	for t in /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB0; do
		[ -c "$t" ] || continue
		[ "$t" = "$PPP_TTY" ] && continue
		CANDIDATES="$CANDIDATES $t"
	done

	# Проверяем ответ на AT
	for p in $CANDIDATES; do
		stty -F "$p" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1 || true
		RESP=$(timeout --foreground 2 sh -c '
			exec 3<>"$1" || exit 1
			printf "AT\r" >&3
			cat <&3 | tr -d "\r"
		' sh "$p" 2>/dev/null || true)
		if echo "$RESP" | grep -q "OK"; then
			echo "$p"
			return 0
		fi
	done

	# Если ничего не ответило, берем первый существующий не-pppd порт
	for p in $CANDIDATES; do
		echo "$p"
		return 0
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
	# Опрос хранилищ SIM ("SM"), встроенной памяти ("ME"), объединенной ("MT")
	# Включаем PDU-режим (AT+CMGF=0) для корректного чтения кириллицы UCS-2 и длинных SMS
	timeout --foreground 12 sh -c '
		P=$1
		exec 3<>"$P" || exit 1
		# Сброс зависшего чтения
		timeout --foreground 1 cat <&3 >/dev/null 2>&1 || true

		# Пробуем хранилище SM (SIM)
		printf "AT+CPMS=\"SM\",\"SM\",\"SM\"\r" >&3
		sleep 0.3
		printf "AT+CMGF=0\r" >&3
		sleep 0.2
		printf "AT+CMGL=4\r" >&3
		sleep 0.8

		# Пробуем хранилище ME (память устройства)
		printf "AT+CPMS=\"ME\",\"ME\",\"ME\"\r" >&3
		sleep 0.3
		printf "AT+CMGL=4\r" >&3
		sleep 0.8

		timeout --foreground 2 cat <&3 | tr -d "\r"
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
		sleep 0.5
		timeout --foreground 2 cat <&3 | tr -d "\r"
	' sh "$PORT" "$TARGET_ID"
	;;

delete_all)
	timeout --foreground 6 sh -c '
		P=$1
		exec 3<>"$P" || exit 1
		# Удалить все сообщения из текущего хранилища (флаг 4)
		printf "AT+CPMS=\"SM\",\"SM\",\"SM\"\r" >&3
		sleep 0.3
		printf "AT+CMGD=1,4\r" >&3
		sleep 0.5
		printf "AT+CPMS=\"ME\",\"ME\",\"ME\"\r" >&3
		sleep 0.3
		printf "AT+CMGD=1,4\r" >&3
		sleep 0.5
		timeout --foreground 2 cat <&3 | tr -d "\r"
	' sh "$PORT"
	;;

*)
	echo "Unknown action: $ACTION"
	exit 1
	;;
esac
