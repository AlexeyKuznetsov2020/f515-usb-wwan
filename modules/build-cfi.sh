#!/bin/bash
# Сборка внешних модулей тем же тулчейном, что и ядро головы F515: clang-11 + ThinLTO
# + CFI. Ядро собрано с CONFIG_CFI_CLANG, из-за чего struct module несёт лишнее поле
# перед init/exit — модуль, собранный обычным gcc-тулчейном, либо не выполнит
# module_init() вовсе (тихо, insmod вернёт успех), либо уронит ядро в панику на
# CFI-проверке. Собирать нужно строго тем же тулчейном.
#
# Собираем IN-TREE (без O=): O= требует чистого дерева ядра, а чистка удалила бы
# артефакты уже существующей сборки. Прежний .config сохраняется копией.
#
# Переменные окружения (все опциональны, дефолты — относительно этого файла):
#   KDIR           каталог исходников ядра этой же версии (обязателен)
#   RUNNING_CONFIG  конфиг, снятый с головы (adb shell zcat /proc/config.gz)
#   TOOLCHAIN_BIN   каталог с симлинками clang/ld.lld/llvm-nm/... (без суффикса версии)
#   SYMVERS         Module.symvers, восстановленный из OEM-модулей (см. extract-symvers.py)
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${KDIR:?"укажи KDIR=/путь/к/исходникам/ядра"}
MOD=${1:?"использование: build-cfi.sh <каталог-внешнего-модуля>"}
RUNNING_CONFIG=${RUNNING_CONFIG:-$HERE/running.config}
TOOLCHAIN_BIN=${TOOLCHAIN_BIN:-$HERE/llvm-bin}
SYMVERS=${SYMVERS:-$HERE/oem.symvers}

# При CONFIG_LTO_CLANG корневой Makefile жёстко прописывает NM/LLVM_NM = llvm-nm
# (без суффикса версии) — если такого бинаря в PATH нет (Debian ставит clang-11 как
# llvm-nm-11), нужен каталог симлинков без суффикса.
if [ -d "$TOOLCHAIN_BIN" ]; then
	export PATH="$TOOLCHAIN_BIN:$PATH"
fi

TOOLS=(
	CC=clang
	LD=ld.lld
	AR=llvm-ar
	NM=llvm-nm
	OBJCOPY=llvm-objcopy
	OBJDUMP=llvm-objdump
	READELF=llvm-readelf
	STRIP=llvm-strip
	HOSTCC=gcc
	HOSTCXX=g++
)
MAKEARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "${TOOLS[@]}")

cd "$SRC"

if ! grep -q "^CONFIG_CFI_CLANG=y" .config 2>/dev/null; then
	[ -f .config ] && cp -f .config "$HERE/config.gcc-backup"   # сохраняем прежний конфиг, если был
	[ -f "$RUNNING_CONFIG" ] || {
		echo "ОШИБКА: нет $RUNNING_CONFIG (снять: adb shell zcat /proc/config.gz > running.config)"
		exit 1
	}
	cp -f "$RUNNING_CONFIG" .config

	echo "== olddefconfig =="
	make "${MAKEARGS[@]}" olddefconfig

	for opt in CONFIG_CFI_CLANG CONFIG_CFI_CLANG_SHADOW CONFIG_LTO_CLANG CONFIG_THINLTO; do
		grep -q "^$opt=y" .config || { echo "ОШИБКА: $opt не выжил после olddefconfig"; exit 1; }
	done
	echo "   CFI/LTO опции на месте"

	echo "== modules_prepare =="
	make "${MAKEARGS[@]}" modules_prepare
fi

# Module.symvers, восстановленный из OEM-модулей головы (extract-symvers.py).
# Даёт запись module_layout в __versions -> ядро проверит раскладку struct module
# и откажет внятной ошибкой вместо тихой порчи mod->init.
if [ -f "$SYMVERS" ]; then
	cp -f "$SYMVERS" Module.symvers
else
	echo "предупреждение: нет $SYMVERS — Module.symvers не будет содержать module_layout"
fi

# oem.symvers покрывает только символы из vendor-модулей головы (USB/TTY среди них
# нет — USB-драйверов в /vendor/lib/modules не поставляется). Наличие в дампе записей
# от "vmlinux" включает в modpost строгую проверку неразрешённых символов, поэтому
# понижаем её до предупреждений: эти символы ядро экспортирует и разрешит при insmod
# (а если нет — будет честное "Unknown symbol" вместо тихой поломки).
echo "== modules: $MOD =="
make "${MAKEARGS[@]}" KBUILD_MODPOST_WARN=1 M="$MOD" modules

echo
echo "== проверка результата =="
for ko in "$MOD"/*.ko; do
	echo "--- $(basename "$ko")"
	llvm-readelf -SW "$ko" | grep -E "this_module|__versions" || true
	llvm-readelf -rW "$ko" 2>/dev/null | grep -A4 "rela.gnu.linkonce.this_module" | grep -E "init_module|cleanup_module" || true
	echo -n "    __cfi_check: "; llvm-readelf -sW "$ko" | grep -c "__cfi_check$" || true
	strings "$ko" | grep -m1 vermagic || true
done
echo
echo "Сверь с любым OEM /vendor/lib/modules/*.ko той же головы: одинаковые смещения"
echo ".init/.exit внутри .gnu.linkonce.this_module, размер секции и наличие __cfi_check."
