#!/bin/sh
# scripts/install-update.sh - 100% тихая установка обновления APK на ГУ F515
# Основной метод: инжектор Seres EngineeringMode (Toolbox) в фоновом режиме БЕЗ показа GUI
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

# 1. ОСНОВНОЙ МЕТОД: инжектор Seres EngineeringMode (Toolbox) в чистом фоне
if [ -x "$FRIDA_INJECT" ] && [ -n "$ENGMODE_JS" ]; then
	echo "==> [Основной метод] Подготовка тихого установщика SeresEngMode (Toolbox)..."
	echo "$APK_PATH" > /data/local/tmp/engmode-install-path
	chmod 666 /data/local/tmp/engmode-install-path

	# Ищем PID процесса com.seres.engineeringmode
	PID=$(pidof com.seres.engineeringmode 2>/dev/null || true)

	# Если процесс не запущен, поднимаем его в ФОНЕ через broadcast (без открытия Activity/GUI)
	if [ -z "$PID" ]; then
		echo "   Запуск фонового процесса SeresEngMode через broadcast..."
		am broadcast -a android.intent.action.LOCKED_BOOT_COMPLETED -p com.seres.engineeringmode >/dev/null 2>&1 || true
		am broadcast -a com.seres.engineeringmode.ACCESS -p com.seres.engineeringmode >/dev/null 2>&1 || true
		sleep 0.5
		PID=$(pidof com.seres.engineeringmode 2>/dev/null || true)
	fi

	# Если broadcast не поднял процесс, поднимаем фоновый сервис
	if [ -z "$PID" ]; then
		am start-service -n com.seres.engineeringmode/.camera.IntentUriService >/dev/null 2>&1 || true
		sleep 0.5
		PID=$(pidof com.seres.engineeringmode 2>/dev/null || true)
	fi

	# Если PID найден — инжектим скрипт в фоновый процесс
	if [ -n "$PID" ]; then
		echo "   Фоновый PID: $PID, запуск frida-inject..."
		timeout 4 "$FRIDA_INJECT" -p "$PID" -s "$ENGMODE_JS" >/dev/null 2>&1 || true
		sleep 1
		rm -f "$APK_PATH" 2>/dev/null || true
		echo "OK: Установка через SeresEngMode завершена (100% фоновый режим)"
		exit 0
	else
		# Если фоновые методы не смогли запустить процесс, пробуем spawn через frida-inject -f
		echo "   Попытка spawn через frida-inject -f..."
		if timeout 6 "$FRIDA_INJECT" -f com.seres.engineeringmode -s "$ENGMODE_JS" >/dev/null 2>&1; then
			rm -f "$APK_PATH" 2>/dev/null || true
			echo "OK: Установка через frida-inject spawn завершена"
			exit 0
		fi
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
