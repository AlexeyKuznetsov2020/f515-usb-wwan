#!/system/bin/sh
# at.sh <порт> "AT..." ["AT..." ...] — отправить AT-команды и показать ответы.
# Без raw/-echo модем эхоит команды и ответы читать невозможно.
P=$1
shift
[ -c "$P" ] || { echo "нет порта $P"; exit 1; }
# Скорость не задаём: toybox stty её на этом драйвере поставить не может и
# тогда отбрасывает всю команду. -iuclc — иначе ответы приходят в нижнем регистре.
stty -F "$P" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1
exec 3<>"$P" || exit 1
timeout 1 cat <&3 >/dev/null 2>&1
for c in "$@"; do
	printf '%s\r' "$c" >&3
	echo "> $c"
	timeout 2 cat <&3 | tr -d '\r'
	echo
done
exec 3<&-
