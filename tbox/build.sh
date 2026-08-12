#!/usr/bin/env bash
# Сборка TboxWire без gradle: javac (1.8) -> d8 -> classes.dex -> zip в tboxwire.jar.
#
# Никакого apk: класс запускается через app_process, а тому нужен именно jar
# с classes.dex внутри (см. ../scripts/tbox-icon.sh). Тулчейн тот же, что в ../app/build.sh.
#
# Готовый jar лежит в prebuilt/ и в app/assets/ — пересобирать не обязательно.
set -euo pipefail

PROJ=$(cd "$(dirname "$0")" && pwd)
OUT=$PROJ/build
JAR=$PROJ/prebuilt/tboxwire.jar

SDK=${ANDROID_SDK:-/home/dsultanr/android-sdk}
BT=${ANDROID_BUILD_TOOLS:-$SDK/android-14}
PLATFORM=${ANDROID_JAR:-$SDK/android-11/android.jar}

D8=$BT/d8

# ---------------------------------------------------------------- проверки тулчейна
if [ ! -x "$D8" ]; then
    cat >&2 <<EOF
не найден d8: $D8
  Ожидается тулчейн, как в ../tbox-emu/build.sh:
    SDK=$SDK, build-tools=$BT
  Переопредели путями:
    ANDROID_SDK=... ANDROID_BUILD_TOOLS=... ANDROID_JAR=... $0
EOF
    exit 1
fi

if ! command -v javac >/dev/null 2>&1; then
    echo "не найден javac — поставь JDK (проверено на openjdk 11)" >&2
    exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
    echo "не найден zip — он нужен, чтобы упаковать classes.dex в jar" >&2
    exit 1
fi

BOOTCP=()
if [ -f "$PLATFORM" ]; then
    echo "== android.jar: $PLATFORM"
    BOOTCP=(-bootclasspath "$PLATFORM")
else
    cat >&2 <<EOF
предупреждение: не найден android.jar ($PLATFORM).
  Компилируем без bootclasspath — javac будет ругаться на android.os.*,
  android.util.Log и android.content.*, и скорее всего упадёт.
  Укажи путь: ANDROID_JAR=/path/to/android.jar $0
EOF
fi

# ------------------------------------------------------------------------- сборка
# Каталог build/ намеренно НЕ вычищается: в этом проекте действует жёсткий запрет
# на самостоятельное удаление чего бы то ни было. Чтобы старые .class-файлы всё же
# не утекали в dex, дексуем только то, что javac записал в этом прогоне (по метке
# времени .stamp).
mkdir -p "$OUT/classes" "$OUT/dex" "$PROJ/prebuilt"
: >"$OUT/.stamp"

echo "== javac (source/target 1.8)"
javac -source 1.8 -target 1.8 -nowarn -encoding UTF-8 \
    "${BOOTCP[@]}" \
    -d "$OUT/classes" "$PROJ/TboxWire.java" 2>&1 |
    grep -v -e 'bootstrap class path' -e 'source value 8' -e 'target value 8' -e '^Note:' || true

if [ ! -f "$OUT/classes/TboxWire.class" ]; then
    echo "javac не выдал TboxWire.class — компиляция провалилась" >&2
    exit 1
fi

CLASSES=$(find "$OUT/classes" -name '*.class' -newer "$OUT/.stamp" | sort)
[ -n "$CLASSES" ] || { echo "javac не обновил ни одного .class" >&2; exit 1; }
echo "   классов: $(echo "$CLASSES" | wc -l)"

echo "== d8 (min-api 26)"
D8_LIB=()
[ -f "$PLATFORM" ] && D8_LIB=(--lib "$PLATFORM")
# shellcheck disable=SC2086
"$D8" --min-api 26 "${D8_LIB[@]}" --output "$OUT/dex" $CLASSES

[ -f "$OUT/dex/classes.dex" ] || { echo "d8 не выдал classes.dex" >&2; exit 1; }

echo "== jar"
# zip обновляет запись classes.dex на месте, старый jar сносить не нужно.
(cd "$OUT/dex" && zip -q -X "$JAR" classes.dex)

echo "== готово"
ls -la "$JAR"
unzip -l "$JAR"
echo
echo "Дальше:"
echo "  cp $JAR ../app/assets/            # чтобы приложение раскладывало свежий"
echo "  adb push $JAR ../scripts/tbox-icon.sh /data/local/tmp/wwan/"
echo "  adb shell sh /data/local/tmp/wwan/tbox-icon.sh start"
