#!/bin/sh
# scripts/install-update.sh - Тихая установка обновления APK на ГУ F515
# Основной метод: инжектор Seres EngineeringMode (Toolbox) с гарантированным автозакрытием
# Резервный метод: pm install
set -e

APK_PATH="${1:-/data/local/tmp/wwan/update.apk}"

if [ ! -f "$APK_PATH" ]; then
	echo "ERROR: APK не найден: $APK_PATH"
	exit 1
fi

chmod 666 "$APK_PATH" 2>/dev/null || true
echo "==> Установка обновления $APK_PATH..."

FRIDA_INJECT="/data/local/tmp/frida-inject"
ENGMODE_JS=""
for p in /data/user/0/com.ispace.toolbox/files/frida/engmode-install.js \
         /data/data/com.ispace.toolbox/files/frida/engmode-install.js; do
	if [ -f "$p" ]; then
		ENGMODE_JS="$p"
		break
	fi
done

# 1. ОСНОВНОЙ МЕТОД: инжектор Seres EngineeringMode (Toolbox)
if [ -x "$FRIDA_INJECT" ] && [ -n "$ENGMODE_JS" ]; then
	echo "==> [Основной метод] Запуск тихого установщика SeresEngMode (Toolbox)..."
	echo "$APK_PATH" > /data/local/tmp/engmode-install-path
	chmod 666 /data/local/tmp/engmode-install-path

	# Запускаем независимый отвязанный таймер, который гарантированно закроет EngineeringMode
	# и вернет наше приложение на экран, даже если текущий процесс приложения будет убит во время обновления
	(
		sleep 2
		am force-stop com.seres.engineeringmode >/dev/null 2>&1 || true
		sleep 0.5
		am start -n su.dsr.f515usbwwan/.MainActivity >/dev/null 2>&1 || true
		rm -f "$APK_PATH" 2>/dev/null || true
	) </dev/null >/dev/null 2>&1 &

	am start -n com.seres.engineeringmode/.MainActivity >/dev/null 2>&1
	sleep 0.5
	PID=$(pidof com.seres.engineeringmode 2>/dev/null || true)
	if [ -n "$PID" ]; then
		echo "   EngMode PID: $PID, запуск frida-inject..."
		timeout 3 "$FRIDA_INJECT" -p "$PID" -s "$ENGMODE_JS" >/dev/null 2>&1 || true
		sleep 0.5
		am force-stop com.seres.engineeringmode >/dev/null 2>&1 || true
		am start -n su.dsr.f515usbwwan/.MainActivity >/dev/null 2>&1 || true
		echo "OK: Установка через SeresEngMode завершена"
		exit 0
	else
		echo "WARN: Не удалось определить PID com.seres.engineeringmode, пробую резервный метод..."
	fi
fi

# 2. РЕЗЕРВНЫЙ МЕТОД: pm install
echo "==> [Резервный метод] Попытка установки через pm install..."
if pm install -r -d "$APK_PATH" 2>&1; then
	echo "OK: Установка через pm install успешна"
	rm -f "$APK_PATH"
	exit 0
fi

echo "ERROR: Не удалось установить APK ни одним из методов"
exit 1
