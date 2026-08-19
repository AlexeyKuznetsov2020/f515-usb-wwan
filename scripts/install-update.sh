#!/bin/sh
# scripts/install-update.sh - Тихая установка обновления APK на ГУ F515
# Использование: sh install-update.sh [/путь/к/update.apk]

APK_PATH="${1:-/data/local/tmp/wwan/update.apk}"

if [ ! -f "$APK_PATH" ]; then
	echo "ERROR: APK не найден: $APK_PATH"
	exit 1
fi

echo "==> Установка обновления $APK_PATH..."

# 1. Попытка через стандартный pm install (работает под root uid 0)
if pm install -r -d "$APK_PATH" 2>&1; then
	echo "OK: Установка через pm install успешна"
	rm -f "$APK_PATH"
	exit 0
fi

echo "WARN: 'pm install' завершился с ошибкой, проверяю SeresEngMode инжектор..."

# 2. Резервный путь через инжектор Seres EngineeringMode (механизм Toolbox)
FRIDA_INJECT="/data/local/tmp/frida-inject"
ENGMODE_JS="/data/user/0/com.ispace.toolbox/files/frida/engmode-install.js"

if [ -x "$FRIDA_INJECT" ] && [ -f "$ENGMODE_JS" ]; then
	echo "==> Вызов тихого установщика SeresEngMode..."
	echo "$APK_PATH" > /data/local/tmp/engmode-install-path
	chmod 666 /data/local/tmp/engmode-install-path
	am start -n com.seres.engineeringmode/.MainActivity >/dev/null 2>&1
	sleep 2
	PID=$(pidof com.seres.engineeringmode 2>/dev/null || true)
	if [ -n "$PID" ]; then
		"$FRIDA_INJECT" -p "$PID" -s "$ENGMODE_JS" 2>&1 || true
		sleep 3
		am force-stop com.seres.engineeringmode >/dev/null 2>&1 || true
		echo "OK: Установка через SeresEngMode завершена"
		rm -f "$APK_PATH"
		exit 0
	else
		echo "ERROR: Не удалось запустить com.seres.engineeringmode"
	fi
fi

echo "ERROR: Все методы тихой установки не удались"
exit 1
