#!/system/bin/sh
# connect-скрипт для pppd: stdin/stdout уже подключены к модемному порту,
# поэтому «общение» с модемом — это обычные printf/read.
#
# Коды выхода использует wwan-up.sh, чтобы объяснить, что именно не получилось
# (pppd пишет их в лог как "status = 0x100 / 0x200 / 0x300"):
#   1 — модем не отвечает на AT
#   2 — модем не принял APN
#   3 — не дождались CONNECT
APN="${APN:-internet}"
NUM="${WWAN_DIAL:-*99#}"

send() { printf '%s\r' "$1"; }

wait_for() {
	n=0
	while [ $n -lt 40 ]; do
		read -r line || return 1
		# На части портов включён iuclc и модем отвечает в нижнем регистре.
		line=$(echo "$line" | tr 'a-z' 'A-Z')
		case "$line" in
		*"$1"*)                 return 0 ;;
		*ERROR* | *"NO CARRIER"* | *"NO DIALTONE"* | *BUSY*) return 1 ;;
		esac
		n=$((n + 1))
	done
	return 1
}

send 'ATZ'
wait_for OK || exit 1
send 'ATE0'
wait_for OK || exit 1
send "AT+CGDCONT=1,\"IP\",\"$APN\""
wait_for OK || exit 2
send "ATD$NUM"
wait_for CONNECT || exit 3
exit 0
