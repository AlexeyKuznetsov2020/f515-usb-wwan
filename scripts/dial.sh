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

# wait_for <что ждём> [сколько чтений]
#
# read обязательно с -t: без таймаута молчащий модем вешает этот скрипт
# навсегда, а вместе с ним и pppd — тот остаётся в памяти, держит модемный порт,
# и следующая попытка дозвона (сторож, кнопка в приложении) даже не начнётся.
# Проверено на живом стенде: ровно так связь и не восстанавливалась.
wait_for() {
	_pat=$1
	_max=${2:-30}
	n=0
	while [ $n -lt "$_max" ]; do
		n=$((n + 1))
		read -t 2 -r line || continue
		# На части портов включён iuclc и модем отвечает в нижнем регистре.
		line=$(echo "$line" | tr 'a-z' 'A-Z')
		case "$line" in
		*"$_pat"*)              return 0 ;;
		*ERROR* | *"NO CARRIER"* | *"NO DIALTONE"* | *BUSY*) return 1 ;;
		esac
	done
	return 1
}

# Модем мог остаться в data-режиме: прошлый pppd убили жёстко, ATH он послать не
# успел, и теперь порт сыплет PPP-кадрами, а на AT не отвечает вообще ничем.
# Вытаскиваем штатной escape-последовательностью: пауза — +++ — пауза — ATH.
# На E3272 после этого приходит NO CARRIER, и порт снова принимает команды.
escape_data_mode() {
	sleep 1.1
	printf '+++'
	sleep 1.1
	send 'ATH'
	wait_for OK 5
}

# Короткая проба перед основным диалогом: если модем в командном режиме, она
# стоит пару секунд, а если нет — сразу видно, что нужен escape.
send 'AT'
if ! wait_for OK 5; then
	escape_data_mode
	send 'AT'
	wait_for OK 5 || exit 1
fi

send 'ATZ'
wait_for OK || exit 1
send 'ATE0'
wait_for OK || exit 1
send "AT+CGDCONT=1,\"IP\",\"$APN\""
wait_for OK || exit 2
send "ATD$NUM"
wait_for CONNECT || exit 3
exit 0
