#!/system/bin/sh
# Перечисляет съёмные USB mass-storage устройства и (по явному выбору пользователя в
# приложении) форматирует одно из них: MBR, один раздел 0x0c (Win95 FAT32, LBA) со
# старта LBA 2048 (1MiB-выравнивание) на весь диск, файловая система exFAT - структурно
# идентично заводской разметке SD/TF-карты, но без привязки к конкретному объёму.
#
# На этой платформе /sys/block/sd* - всегда USB SCSI mass-storage (модем, флешка и т.п.),
# внутреннее хранилище живёт на /dev/block/vd*|dm-*, поэтому список сам по себе не может
# случайно содержать системный раздел. Какое именно устройство форматировать - решает
# пользователь в приложении (после явного подтверждения), скрипт сам ничего не угадывает.
#
#   format-sdcard.sh --list           напечатать кандидатов, ничего не менять
#   format-sdcard.sh --format=sdX     стереть и переразметить /dev/block/sdX
TMP=/data/local/tmp
LOG=$TMP/f515usbwwan.log

log() { echo "$(date '+%F %T') format-sdcard: $*" >> $LOG; }

human_size() {
    # $1 - размер в 512-байтных секторах
    awk -v s="$1" 'BEGIN {
        b = s * 512
        if (b >= 1073741824) printf "%.1fG", b/1073741824
        else if (b >= 1048576) printf "%.1fM", b/1048576
        else printf "%dK", b/1024
    }'
}

list_candidates() {
    for d in /sys/block/sd*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        sectors=$(cat "$d/size" 2>/dev/null)
        [ -n "$sectors" ] || continue
        vendor=$(cat "$d/device/vendor" 2>/dev/null | sed 's/^ *//;s/ *$//')
        model=$(cat "$d/device/model" 2>/dev/null | sed 's/^ *//;s/ *$//')
        size=$(human_size "$sectors")
        part="/dev/block/${name}1"
        fstype=""
        label=""
        if [ -b "$part" ]; then
            info=$(blkid "$part" 2>/dev/null)
            fstype=$(echo "$info" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
            label=$(echo "$info" | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
        fi
        echo "${name}|${vendor}|${model}|${size}|${fstype}|${label}"
    done
}

do_format() {
    dev=$1
    case "$dev" in
        sd[a-z]) ;;
        *) echo "недопустимое имя устройства: $dev"; exit 1 ;;
    esac
    node="/dev/block/$dev"
    if [ ! -b "$node" ]; then
        echo "$node не найден"
        log "format: $node not found"
        exit 1
    fi

    # Android монтирует съёмные тома через vold под алиасом /dev/block/vold/public:MAJOR,MINOR,
    # а не по прямому пути /dev/block/sdXN - обычный umount по прямому пути ничего не находит,
    # том остаётся занят, из-за чего и BLKRRPART, и последующий mkfs падают с "Device or
    # resource busy". Отпускать нужно через vold же (sm unmount), а не голым umount.
    part="${node}1"
    if [ -e "/sys/class/block/${dev}1/dev" ]; then
        majmin=$(cat "/sys/class/block/${dev}1/dev" 2>/dev/null | tr ':' ',')
        if [ -n "$majmin" ]; then
            echo "размонтирую public:$majmin через vold..."
            sm unmount "public:$majmin" >>$LOG 2>&1
            sleep 1
        fi
    fi
    # на всякий случай - если том смонтирован не через vold (не должно быть, но не помешает)
    for p in ${node}*; do
        [ "$p" = "$node" ] && continue
        mp=$(mount | grep "^$p " | awk '{print $3}')
        [ -n "$mp" ] && umount "$p" 2>/dev/null
    done

    echo "создаю разметку (MBR, раздел 1, старт LBA 2048, на весь диск, тип 0x0c)..."
    printf "o\nn\np\n1\n2048\n\nt\nc\nw\n" | busybox fdisk "$node" >>$LOG 2>&1
    sync
    sleep 1
    blockdev --rereadpt "$node" 2>/dev/null

    i=0
    while [ ! -b "$part" ] && [ $i -lt 5 ]; do
        sleep 1
        i=$((i + 1))
    done
    if [ ! -b "$part" ]; then
        echo "раздел $part не появился после разметки"
        log "format: $part missing after fdisk"
        exit 1
    fi

    # После смены таблицы разделов ядро шлёт uevent, и vold ненадолго сам открывает
    # устройство для проверки (пробует смонтировать) - mkfs может попасть точно в это
    # окно и получить "Device or resource busy", хотя ни mount, ни lsof в спокойном
    # состоянии ничего не показывают. Поэтому - несколько попыток с повторным
    # sm unmount перед каждой, а не одна попытка в лоб.
    echo "форматирую $part в exFAT..."
    ok=0
    i=0
    while [ $i -lt 6 ]; do
        [ -n "$majmin" ] && sm unmount "public:$majmin" >>$LOG 2>&1
        if mkfs.exfat "$part" >>$LOG 2>&1; then
            ok=1
            break
        fi
        i=$((i + 1))
        sleep 2
    done
    if [ "$ok" != 1 ]; then
        echo "mkfs.exfat завершился с ошибкой (после $i попыток)"
        log "format: mkfs.exfat failed on $part after $i attempts"
        exit 1
    fi
    log "format complete: $part"

    # После mkfs том остаётся в состоянии "unmountable", пока vold не пересканирует его
    # заново - без этого шага новая ФС видна ядру и blkid, но недоступна как /storage/...
    # и приложениям (например видеорегистратору) не видна, пока кто-то не смонтирует
    # руками через sm mount.
    echo "монтирую..."
    mounted=0
    i=0
    while [ $i -lt 5 ]; do
        if [ -n "$majmin" ] && sm mount "public:$majmin" >>$LOG 2>&1; then
            sleep 1
            case "$(sm list-volumes 2>/dev/null)" in
                *"public:$majmin mounted"*) mounted=1; break ;;
            esac
        fi
        i=$((i + 1))
        sleep 1
    done
    if [ "$mounted" = 1 ]; then
        log "mount complete: public:$majmin"
        echo "готово: $part отформатирован и смонтирован (exFAT)"
    else
        log "format ok but mount failed: public:$majmin"
        echo "отформатирован, но не примонтировался автоматически - переподключите модем/карту"
    fi
}

case "$1" in
    --list)
        list_candidates
        ;;
    --format=*)
        do_format "${1#--format=}"
        ;;
    *)
        echo "usage: format-sdcard.sh --list | --format=sdX"
        exit 1
        ;;
esac
