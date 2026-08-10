# Модули ядра: usbserialmerged2, ppp_async

Ядро головы (`5.4.86-qgki-...`) не собрано с `CONFIG_USB_SERIAL` и `CONFIG_PPP_ASYNC` —
без них Huawei-модем не отдаёт AT/PPP-порты и PPP-дозвон невозможен. Готовые `.ko` лежат
в [`prebuilt/`](prebuilt/) и подходят ровно для этого ядра (совпадение проверяется по
`vermagic` прямо в `wwan-up.sh` перед загрузкой). Пересобирать нужно только если у тебя
другая версия ядра/сборки.

## Важно: тулчейн должен совпадать с ядром

Ядро головы собрано **clang + ThinLTO + CFI** (Control Flow Integrity). Модуль, собранный
обычным gcc-тулчейном, при загрузке либо не выполнит `module_init()` вовсе (тихо, без
ошибки — `insmod` вернёт успех), либо уронит ядро в панику на CFI-проверке. Собирать нужно
строго тем же тулчейном, что и ядро — `build-cfi.sh` делает это автоматически.

## Пересборка

```bash
# Debian: clang-11 + lld-11
sudo apt install clang-11 lld-11 aarch64-linux-gnu-gcc

# 1. Снять реальный конфиг с головы (там правда о CFI/LTO)
adb shell zcat /proc/config.gz > running.config   # или /proc/config, смотря что есть

# 2. Положить исходники ядра этой же версии в SRC (см. build-cfi.sh)
# 3. Собрать
./build-cfi.sh src/usbserial
./build-cfi.sh src/ppp
```

`build-cfi.sh` при первом запуске конфигурирует дерево ядра под этот тулчейн
(`running.config` + `olddefconfig`), после чего собирает указанный внешний модуль и
сверяет результат с ожидаемой раскладкой `struct module` (`.init`/`.exit`/`__cfi_check`).

## Module.symvers — проверка совпадения с ядром "из коробки"

`oem.symvers` восстановлен из штатных `/vendor/lib/modules/*.ko` этой прошивки
(`extract-symvers.py`) и содержит CRC символа `module_layout` — по нему ядро само
проверяет, что раскладка `struct module` совпадает, и откажет понятной ошибкой
(`disagrees about version of symbol module_layout`) вместо тихой порчи памяти, если
тулчейн вдруг разъедется с ядром. `build-cfi.sh` подставляет его автоматически.

```bash
python3 extract-symvers.py oem.symvers /vendor/lib/modules/*.ko   # только если нужно обновить
```

## Файлы

- `src/usbserial/` — копии `usb-serial.c`, `bus.c`, `generic.c`, `option.c`, `usb_wwan.c`
  из `drivers/usb/serial/` апстримного дерева этого ядра, собираются в один
  `usbserialmerged2.ko`.
- `src/ppp/ppp_async.c` — копия `drivers/net/ppp/ppp_async.c`, даёt line discipline `ppp`.
- `prebuilt/*.ko` — готовые модули для `5.4.86-qgki-g310fb9b27fcd-dirty`.
- `build-cfi.sh`, `extract-symvers.py`, `oem.symvers` — инструменты пересборки.
