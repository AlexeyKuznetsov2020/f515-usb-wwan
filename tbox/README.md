# tbox/ — эмуляция блока TBOX для иконки сотовой сети

`TboxWire.java` притворяется блоком TBOX, которого на голове нет, и отдаёт ей по SOME/IP
силу сигнала и тип сети нашего USB-модема. Из-за этого штатная иконка мобильной сети в
статус-баре показывает модем, а не крестик.

Зачем, как это работает на проводе, что рисуется от каких значений и как отлаживать —
[../docs/status-icon.md](../docs/status-icon.md). Запуск — `../scripts/tbox-icon.sh`.

| Файл | Что |
|---|---|
| `TboxWire.java` | весь код: SOME/IP-SD, события и опрос модема (AT или веб-API HiLink) |
| `build.sh` | javac 1.8 → d8 → `prebuilt/tboxwire.jar` (никакого gradle и apk) |
| `prebuilt/tboxwire.jar` | собранный jar; его же `app/build.sh` кладёт в assets приложения |

Запускается через `app_process` (это jar с `classes.dex` внутри, а не apk), поэтому и
собирается без Android-проекта — хватает `javac` и `d8` из build-tools.
