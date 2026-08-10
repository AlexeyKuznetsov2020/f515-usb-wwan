# huawei-modeswitch

Переводит Huawei-модем из storage-режима (`12d1:14fe` и похожие — модем притворяется
флешкой/CD-ROM с драйверами) в режим с AT/PPP-портами (`12d1:1506` и похожие). Делает то
же, что штатный `usb_modeswitch`: находит mass-storage интерфейс модема, отправляет в его
bulk-OUT endpoint 31-байтовую SCSI-команду напрямую через usbfs
(`/dev/bus/usb/BBB/DDD`) — без `usb_modeswitch`, которого на голове нет.

## Сборка

```bash
./build-tools.sh          # aarch64-linux-gnu-gcc -static -> huawei-modeswitch
```

Статическая линковка — на голове нет ни динамического линкера для стороннего glibc, ни
самого `usb_modeswitch`; программа использует только `open`/`read`/`ioctl`, так что
`-static` здесь безопасен.

## Использование

```bash
huawei-modeswitch          # найти Huawei в storage-режиме и переключить
huawei-modeswitch -n       # dry-run: только показать, что нашлось
huawei-modeswitch -n /dev/bus/usb/002/002   # разобрать конкретное устройство
```

`wwan-up.sh` вызывает его сам на стадии 4, если видит модем в storage-режиме — отдельно
руками обычно не нужен.
