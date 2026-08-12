# Три апстримных драйвера из дерева ядра головы, собранные ВНЕШНИМИ модулями.
# В конфиге головы они выключены (CONFIG_USB_NET_CDC_NCM / CONFIG_USB_NET_HUAWEI_CDC_NCM
# / CONFIG_USB_WDM = n), хотя каркас для них — usbnet — уже встроен в ядро
# (CONFIG_USB_USBNET=y, CONFIG_MII=y, 41 экспортируемый символ usbnet_*).
# Дают сетевой интерфейс HiLink-модемам Huawei, у которых канал данных — NCM
# на vendor-specific интерфейсе ff/02/16 (E8278, E8372, E3372 в NCM-режиме).
#
# В отличие от usbserialmerged2 в один .ko НЕ сливаем: исходники нужны ровно
# апстримные, без правок, а межмодульные символы (usb_cdc_wdm_register,
# cdc_ncm_bind_common и т.д.) modpost разрешает сам — все три собираются одним
# проходом M= с общим Module.symvers.
#
# Порядок загрузки на голове: cdc-wdm -> cdc_ncm -> huawei_cdc_ncm.
obj-m += cdc-wdm.o
obj-m += cdc_ncm.o
obj-m += huawei_cdc_ncm.o
