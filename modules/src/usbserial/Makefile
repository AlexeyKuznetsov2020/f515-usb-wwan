# Слитый usb-serial+option драйвер как ВНЕШНИЙ модуль, чтобы собирать его
# clang+ThinLTO+CFI через O=build-cfi, не трогая in-tree дерево.
# Слияние в один .ko (без EXPORT_SYMBOL) осталось с прошлой сессии; причина
# тогдашних крашей была другой (см. "доп. 6" в MODEM_KERNEL_MODULE_INVESTIGATION.md),
# так что при желании можно вернуться к раздельной апстрим-сборке.
obj-m += usbserialmerged2.o
usbserialmerged2-y := usb-serial.o bus.o generic.o option.o usb_wwan.o
