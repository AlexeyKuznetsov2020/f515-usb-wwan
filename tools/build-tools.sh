#!/bin/bash
# Сборка huawei-modeswitch под aarch64, статически: на голове нет ни glibc-loader'а
# для чужих бинарей, ни usb_modeswitch. Программа использует только open/read/ioctl,
# поэтому статическая линковка с glibc здесь безопасна (никакого NSS/dlopen).
set -e
cd "$(dirname "$0")"
CC=${CC:-aarch64-linux-gnu-gcc}
$CC -O2 -Wall -Wextra -static -o huawei-modeswitch huawei-modeswitch.c
aarch64-linux-gnu-strip huawei-modeswitch 2>/dev/null || true
ls -l huawei-modeswitch
file huawei-modeswitch 2>/dev/null || true
