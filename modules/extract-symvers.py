#!/usr/bin/env python3
"""
Восстанавливает Module.symvers из готовых OEM-модулей головы F515.

Каждый .ko, собранный с CONFIG_MODVERSIONS, несёт секцию __versions —
массив struct modversion_info { unsigned long crc; char name[56]; }
(64 байта на запись). Это CRC, посчитанные НАСТОЯЩЕЙ сборкой ядра,
т.е. ровно то, чего нам не хватало.

Самая важная запись — module_layout: её CRC кодирует раскладку
struct module. Имея её в Module.symvers, наш модуль получит запись в
__versions, и ядро при insmod проверит layout и откажет внятной ошибкой
("disagrees about version of symbol module_layout") вместо тихой порчи
mod->init и последующей паники.

Использование:
    python3 extract-symvers.py out.symvers /path/to/*.ko
"""
import sys
import struct

ENTRY = 64          # sizeof(struct modversion_info) на arm64
NAME_LEN = 56       # MODULE_NAME_LEN = 64 - sizeof(unsigned long)


def sections(data):
    """Минимальный разбор ELF64-LE: возвращает {имя_секции: bytes}."""
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        raise ValueError('не ELF64-LE')
    e_shoff, = struct.unpack_from('<Q', data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', data, 0x3a)

    def shdr(i):
        off = e_shoff + i * e_shentsize
        name, _typ, _flags, _addr, offset, size = struct.unpack_from('<IIQQQQ', data, off)
        return name, offset, size

    _, stroff, strsize = shdr(e_shstrndx)
    shstr = data[stroff:stroff + strsize]
    out = {}
    for i in range(e_shnum):
        name_off, offset, size = shdr(i)
        end = shstr.index(b'\0', name_off)
        out[shstr[name_off:end].decode()] = data[offset:offset + size]
    return out


def versions(path):
    with open(path, 'rb') as f:
        sec = sections(f.read()).get('__versions', b'')
    for i in range(0, len(sec) - ENTRY + 1, ENTRY):
        crc, = struct.unpack_from('<Q', sec, i)
        raw = sec[i + 8:i + 8 + NAME_LEN]
        name = raw.split(b'\0', 1)[0].decode('ascii', 'replace')
        if name:
            yield name, crc


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out_path, kos = sys.argv[1], sys.argv[2:]

    syms = {}
    conflicts = []
    for ko in kos:
        try:
            for name, crc in versions(ko):
                if name in syms and syms[name] != crc:
                    conflicts.append((name, syms[name], crc, ko))
                syms[name] = crc
        except Exception as e:                                  # noqa: BLE001
            print(f'  пропущен {ko}: {e}', file=sys.stderr)

    with open(out_path, 'w') as f:
        for name in sorted(syms):
            # Формат Module.symvers в этом дереве — ПЯТЬ полей:
            # CRC \t symbol \t module \t export-type \t namespace
            # (см. read_dump() в scripts/mod/modpost.c). Namespace оставляем
            # пустым, но завершающий таб обязателен, иначе "parse error in
            # symbol dump file".
            f.write(f'0x{syms[name]:08x}\t{name}\tvmlinux\tEXPORT_SYMBOL\t\n')

    print(f'{len(syms)} символов из {len(kos)} модулей -> {out_path}')
    if conflicts:
        print(f'ВНИМАНИЕ: {len(conflicts)} конфликтов CRC', file=sys.stderr)
        for c in conflicts[:5]:
            print(f'  {c[0]}: 0x{c[1]:08x} vs 0x{c[2]:08x} ({c[3]})', file=sys.stderr)
    if 'module_layout' in syms:
        print(f'module_layout CRC = 0x{syms["module_layout"]:08x}  <-- оракул layout')
    else:
        print('module_layout НЕ найден', file=sys.stderr)


if __name__ == '__main__':
    main()
