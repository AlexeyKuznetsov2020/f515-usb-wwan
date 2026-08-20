/**
 * TboxWire — штатная иконка сотовой сети в статус-баре головы F515 показывает сигнал
 * нашего USB-модема.
 *
 * Как это работает. В машине за мобильную сеть отвечает отдельный блок TBOX, который
 * отдаёт голове данные по SOME/IP (сервис INI_CellularNetwork, 0x8002). На стенде TBOX'а
 * нет, поэтому иконка — крестик. Мы этим TBOX'ом и притворяемся: шлём OfferService,
 * отвечаем на подписку и раз в несколько секунд шлём событие reportCellularNetworkInfo
 * с реальными цифрами модема. Дальше всё родное: INI_CellularNetworkProxy →
 * CellularInfoStatus → ключи ID_CELLULAR_* → SeresStatusBarSignalPolicy → иконка.
 *
 * Почему на проводе, а не через вендорский рантайм. Провод обслуживает отдельный демон
 * /vendor/bin/ktsomeipd (он держит сокеты 192.168.62.4:30490 и 239.0.0.255:30490), а в
 * его статическом /vendor/etc/ksomeip-service.json у INI_CellularNetwork есть только
 * ClientCfg — голова там КЛИЕНТ, серверной роли для 0x8002 у неё нет. Регистрация своего
 * skeleton через HIDL-HAL android.vendor.ara.com@2.0-service проходит без единой ошибки и
 * не даёт при этом ни одного пакета на проводе (проверено на железе 2026-08-11). Раз
 * голова клиент — надо не заставлять её оферить, а стать для неё сервером.
 *
 * Адрес источника. Пакеты должны идти НЕ с 192.168.62.4 (это сама голова), иначе стек
 * рискует принять их за собственные. Поэтому на vlan62 вешается алиас 192.168.62.37
 * (в permanent-ARP QNX на vlan62 значатся .1, .5, .10, .14, .37; .5 — QNX, .4 — Android,
 * физического TBOX на стенде нет). Всё общение локальное, в пределах одного хоста,
 * поэтому чужой MAC в статическом ARP роли не играет. Алиас вешает scripts/tbox-icon.sh.
 *
 * Источник цифр зависит от типа модема — того же, что определяет wwan-up.sh:
 *   ppp    — AT+CSQ и AT+COPS? на управляющем порту (его находит wwan-up.sh перебором
 *            и кладёт в state/at-tty: bInterfaceProtocol == 12 есть не у всех свистков);
 *   hilink — веб-API самого модема на его шлюзе (Huawei /api/monitoring/status,
 *            ZTE /goform/goform_get_cmd_process), AT-порта у него обычно нет.
 * Тип не задаётся руками: WAN-интерфейс ppp* — значит ppp, всё остальное — hilink.
 *
 * Запуск: scripts/tbox-icon.sh. Разовый опрос модема без всякого SOME/IP: --signal.
 */

import java.net.HttpURLConnection;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.Date;

public final class TboxWire {

    // ------------------------------------------------------------------ константы провода
    // Всё сверено с /vendor/etc/ksomeip-service.json (сервис №6) и java-манифестом
    // ics/ini_cellularnetwork/ini_cellularnetwork_manifest.java.


    // Значения полей CellularNetworkInfo (см. раздел 3 ~/f515/TBOX_SOMEIP_EMULATION.md).
    //
    // celluarRegisterStatus голова гоняет через switch в SeresStatusBarSignalPolicy.a():
    //   1,2,21,22,23,25,26                  -> состояние иконки 1
    //   3,4,7,14,15,16,17,18,19,20,24       -> 2
    //   6                                   -> 3   (проверено на железе: это 4G)
    //   10,11,12,13                         -> 4
    //   5,8,9 и всё остальное               -> 0   (иконка «нет сети», strength сбрасывается в -1)
    // Имён у этих состояний в прошивке нет (ни enum, ни строк), поэтому подтверждено только
    // «3 == 4G». Что 1/2/4 — это 2G/3G/5G, следует из порядка и размера групп, но глазами не
    // проверено: посмотреть можно `tbox-icon.sh fake 4 --reg N`.
    static final int REG_NONE = 0;
    static final int REG_2G = 1;
    static final int REG_3G = 3;
    static final int REG_4G = 6;
    static final int REG_5G = 10;
    static final int REG_STATUS_REGISTERED = REG_4G;   // если тип сети выяснить не вышло
    static final int REG_STATUS_NONE = REG_NONE;
    // Эти три поля голова принимает, но на иконку они не влияют вообще: SystemUI подписан
    // только на ID_CELLULAR_SIGNAL_SYSTEM, _STRENGTH и _ON_OFF_CARD. Оставлены осмысленными
    // на случай, если их читает кто-то ещё.

    // ------------------------------------------------------------------ источник сигнала
    // Состояние WAN пишет wwan-up.sh: state/wan-iface — имя поднятого интерфейса.
    static String wwanDir = "/data/local/tmp/wwan";
    // ttyUSB0 в конце: на старых свистках (E173) AT отвечает и он, но это же порт для
    // pppd, и занимать его без нужды не стоит — пробуем только когда молчат остальные.
    static final String[] FALLBACK_AT_TTYS = { "/dev/ttyUSB1", "/dev/ttyUSB2", "/dev/ttyUSB0" };
    static final int MODEM_POLL_MS = 15000;       // одна AT-сессия занимает ~3 с, чаще незачем
    static final int STRENGTH_WHEN_UNKNOWN = 3;   // линк есть, а цифр нет — рисуем середину
    static final int HTTP_TIMEOUT_MS = 3000;
    // Регистр важен: модем отвечает строчными буквами ("+csq: 18,99") — stty на этом
    // драйвере не применяется, а значит и -iuclc не работает. Поэтому CASE_INSENSITIVE.
    static final java.util.regex.Pattern CSQ_RE = java.util.regex.Pattern.compile(
            "\\+CSQ:\\s*(\\d+)\\s*,", java.util.regex.Pattern.CASE_INSENSITIVE);
    // +COPS: 0,0,"Beeline",7 — последнее число это access technology.
    static final java.util.regex.Pattern COPS_RE = java.util.regex.Pattern.compile(
            "\\+COPS:\\s*\\d+\\s*,\\s*\\d+\\s*,\\s*\"([^\"]*)\"\\s*,\\s*(\\d+)",
            java.util.regex.Pattern.CASE_INSENSITIVE);
    // +CREG: 0,1 — второе число это состояние регистрации в сети.
    static final java.util.regex.Pattern CREG_RE = java.util.regex.Pattern.compile(
            "\\+CREG:\\s*\\d+\\s*,\\s*(\\d+)", java.util.regex.Pattern.CASE_INSENSITIVE);

    // ------------------------------------------------------------------ параметры запуска
    static int notifyMs = 5000;
    // Фазы уведомлений. IDLE — обычный режим, шлём то, что намерил модем; остальные две
    // рисуют анимацию вместо заглушки, каждая со своим тактом. Опрос модема от этого чаще
    // не становится: он живёт в своём потоке со своим периодом MODEM_POLL_MS, а нотификатор
    // только читает последнее значение и подменяет то, что уходит на провод.
    static final int PHASE_IDLE = 0;
    /** Приложение дождалось adbd и проверяет файлы: крестик ↔ полная шкала раз в секунду. */
    static final int PHASE_APPCHECK = 1;
    /** Работает wwan-up.sh: палки бегут по кругу 0→4, полный пробег за 2.5 с. */
    static final int PHASE_BRINGUP = 2;

    static final int APPCHECK_NOTIFY_MS = 1000;
    static final int CONNECTING_NOTIFY_MS = 500;

    static int phaseTickMs(int phase) {
        return phase == PHASE_APPCHECK ? APPCHECK_NOTIFY_MS : CONNECTING_NOTIFY_MS;
    }
    static int fixedStrength = Integer.MIN_VALUE;  // MIN_VALUE == брать реальный сигнал модема
    static boolean signalOnly = false; // разовый опрос модема и выход, без SOME/IP
    static String gwOverride = null;   // адрес веб-API hilink-модема, если не угадывается
    static int regOverride = -1;       // сырой celluarRegisterStatus — посмотреть, что нарисуется
    // --signal-file PATH: второй, файловый путь для машины БЕЗ опции TBOX (config tbox=0). Там
    // панель не подписывается на ID_CELLULAR_* (SystemUI гейт по ID_CELLULAR_ENABLE), поэтому
    // SOME/IP-события никто не слушает. Вместо этого пишем reg/strength в tmpfs-файл, который
    // читает Frida-твик iSpaceToolbox «Статус сети» (com.android.systemui) и рисует иконку
    // напрямую. tbox-icon.sh передаёт ключ ВСЕГДА, не спрашивая конфиг машины: на tbox=1 файл
    // просто никто не читает, зато ошибка в определении режима (а на раннем старте конфиг может
    // ещё не читаться) не оставляет голову без иконки. SOME/IP работает в обоих случаях.
    // Формат строки: "<reg> <strength> <card> <monoSec>" (monoSec = /proc/uptime, для проверки свежести).
    static String signalFile = null;

    static volatile int session = 1;

    static final SimpleDateFormat TS = new SimpleDateFormat("HH:mm:ss.SSS");

    static void say(String s) {
        System.out.println("[tboxwire " + TS.format(new Date()) + "] " + s);
        System.out.flush();
    }

    // ------------------------------------------------------- сколько писать в лог
    //
    // Голова обновляет подписку каждые ~3 секунды (столько живёт ttl), и на каждое
    // обновление раньше уходило по две строки. Это 400 строк в минуту и 29 МБ файла
    // за несколько дней, из которых 97% — одно и то же. Полезного там ровно один бит:
    // «процесс жив и голова с нами разговаривает».
    //
    // Поэтому: первая подписка на каждую eventgroup — целиком, дальше только счётчик
    // раз в SUB_SUMMARY_MS. События наружу — только когда цифры изменились, плюс
    // редкий маячок, чтобы по логу было видно, что мы живы. Всё необычное (чужой
    // сервис, отвалившийся клиент, медленная запись) пишется как писалось: молчание
    // должно означать «всё ровно», а не «мы перестали смотреть».
    static final int NOTIFY_HEARTBEAT_MS = 600000;

    static int lastLoggedReg = Integer.MIN_VALUE;
    static int lastLoggedStrength = Integer.MIN_VALUE;
    static long lastNotifyLogNs = 0;


    /** Стоит ли писать строку про очередной сигнал: только смена или редкий маячок. */
    static boolean notifyWorthLogging(Sig sig) {
        long now = System.nanoTime();
        boolean changed = sig.reg != lastLoggedReg || sig.strength != lastLoggedStrength;
        boolean heartbeat = now - lastNotifyLogNs >= NOTIFY_HEARTBEAT_MS * 1000000L;
        if (!changed && !heartbeat) return false;
        lastLoggedReg = sig.reg;
        lastLoggedStrength = sig.strength;
        lastNotifyLogNs = now;
        return true;
    }

    // ------------------------------------------------------------------------- main

    public static void main(String[] args) throws Exception {
        parseArgs(args);

        if (signalOnly) { dumpSignal(); return; }

        say("=================== сигнал в файл ===================");
        say("источник: " + (fixedStrength != Integer.MIN_VALUE
                ? ("фиксированный strength=" + fixedStrength) : "реальный модем"));
        say("файл:     " + signalFile + ", такт " + notifyMs + " мс");
        say("====================================================");

        if (signalFile == null) {
            say("--signal-file не задан: писать некуда, выхожу");
            return;
        }

        // Опрос модема — раньше нотификатора: к первому такту уже есть что писать.
        startPoller();
        runNotifier();
    }







    /** Монотонные секунды из /proc/uptime — как у твика; настенные часы головы прыгают. */
    static long uptimeSec() {
        try {
            java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader("/proc/uptime"));
            String l = r.readLine();
            r.close();
            return (long) Double.parseDouble(l.trim().split("\\s+")[0]);
        } catch (Exception e) { return 0; }
    }

    // Зеркалим сигнал в tmpfs-файл signalFile: "<reg> <strength> <card> <monoSec>".
    // Прямая перезапись (не temp+rename), чтобы сохранить mode 666, выставленный один раз при
    // создании (rename дал бы новый inode с umask-режимом — SystemUI под u0_a33 не прочитал бы).
    // Рваное чтение маловероятно и на стороне твика лечится проверкой формата + свежести.
    static void writeSignalFile(Sig sig) {
        try {
            int card = sig.strength >= 0 ? 1 : 0;
            String line = sig.reg + " " + sig.strength + " " + card + " " + uptimeSec() + "\n";
            java.io.File f = new java.io.File(signalFile);
            // Обычно файл заводит tbox-icon.sh и сразу ставит 666, но если его почему-то не
            // оказалось, создаём мы — под root и с umask, то есть 600, и твик в SystemUI молча
            // не прочитал бы ни байта. Права ставим ровно при создании: inode дальше тот же.
            boolean fresh = !f.exists();
            java.io.FileOutputStream fos = new java.io.FileOutputStream(f);
            fos.write(line.getBytes("US-ASCII"));
            fos.close();
            if (fresh) f.setReadable(true, false);
        } catch (Exception e) { /* tmpfs-мост, разовые ошибки не важны */ }
    }

    /**
     * Такт записи сигнала в файл. Крутится в основном потоке: больше делать нечего.
     *
     * Фазы и анимация оставлены как были — они про то, ЧТО показывать, пока настоящего
     * уровня ещё нет, и к способу доставки отношения не имеют.
     */
    static void runNotifier() {
        int tick = 0;
        int phase = PHASE_IDLE;
        while (true) {
            try {
                // Такт задаёт текущая фаза: на пяти секундах и «бег» палок, и мигание
                // выглядят не движением, а случайными скачками уровня.
                Thread.sleep(phase == PHASE_IDLE ? notifyMs : phaseTickMs(phase));
            } catch (InterruptedException e) { return; }
            Sig sig = readSignal();
            // Настоящего уровня ещё нет — значит, возможно, идёт одна из двух ранних
            // стадий, и вместо заглушки надо показать, что процесс живой.
            //
            // Стадии РОВНО ДВЕ и они не пересекаются: сначала приложение проверяет adbd и
            // раскладывает файлы (state/appboot=1), потом работает wwan-up.sh (state/busy с
            // живым pid). Порядок проверок ниже задаёт приоритет: «моргание» не может
            // перебить «бегущие палки».
            int next = PHASE_IDLE;
            if (!sig.measured) {
                String stage = bringUpStage();
                if (stage != null) {
                    next = PHASE_BRINGUP;
                    sig = new Sig(REG_STATUS_REGISTERED, connectingStrength(tick++),
                            "подключение: " + stage);
                } else if (appChecking()) {
                    next = PHASE_APPCHECK;
                    boolean full = (tick++ & 1) == 0;
                    sig = full
                            ? new Sig(REG_STATUS_REGISTERED, 5, "автозапуск: проверки")
                            : new Sig(REG_NONE, -1, "автозапуск: проверки");
                }
            }
            // Фаза сменилась — счёт кадров начинается заново, иначе новая анимация
            // подхватывает чужой такт и первый кадр выпадает случайным.
            if (next != phase) tick = 0;
            phase = next;

            writeSignalFile(sig);
            if (notifyWorthLogging(sig)) {
                say("сигнал: reg=" + sig.reg + " strength=" + sig.strength
                        + " (" + sig.detail + ")");
            }
        }
    }



    // ================================================================== опрос модема ====
    //
    // Два типа модемов — ровно те же, что различает wwan-up.sh:
    //   ppp    (Huawei E17x/E3272): есть AT-порт, спрашиваем AT+CSQ и AT+COPS?;
    //   hilink (ZTE MF833R и прочие CDC-Ethernet): AT-порта нет, но есть веб-API на
    //          собственном шлюзе модема — там и сила сигнала, и тип сети.
    // Тип определяем по имени WAN-интерфейса: ppp* — первое, всё остальное — второе.

    /** Что мы знаем о сигнале прямо сейчас. */
    static final class Sig {
        final int reg;         // celluarRegisterStatus: 0 — сети нет, 6 — 4G
        final int strength;    // 0..5, -1 — неизвестно
        final String detail;   // человеческое пояснение для лога
        /**
         * Уровень измерен по-настоящему (CSQ у ppp, signalbar у hilink), а не подставлен.
         * Именно этим отличается «показываем реальный сигнал» от «пока сказать нечего»: во
         * втором случае в поля уходит правдоподобная заглушка (4G + три палки), по которой
         * снаружи не отличить готовую сеть от модема, который ещё даже не ответил.
         */
        final boolean measured;
        Sig(int reg, int strength, String detail) {
            this(reg, strength, detail, false);
        }
        Sig(int reg, int strength, String detail, boolean measured) {
            this.reg = reg; this.strength = strength; this.detail = detail;
            this.measured = measured;
        }
    }

    static volatile Sig cachedSignal = null;

    /**
     * Мгновенный доступ к последнему намеренному значению. НИЧЕГО не блокирует.
     *
     * Опрос модема отсюда убран намеренно. Раньше он шёл прямо в такте нотификатора, и
     * 2026-08-12 после выхода из сна одна итерация цикла заняла 4 минуты 40 секунд
     * (уведомления #199 и #200 идут подряд по номерам, но с такой дырой по времени).
     * Всё это время в SystemUI не уходило ни одного события, подписка живёт три секунды —
     * и иконка сваливалась в крестик ровно тогда, когда анимация должна была показывать,
     * что подъём идёт. Теперь блокирующая работа заперта в отдельном потоке, а такт
     * нотификатора не может встать ни при каких обстоятельствах.
     */
    static Sig readSignal() {
        if (fixedStrength != Integer.MIN_VALUE) {
            int reg = regOverride >= 0 ? regOverride
                    : (fixedStrength < 0 ? REG_NONE : REG_STATUS_REGISTERED);
            return new Sig(reg, fixedStrength, "--strength");
        }
        Sig s = cachedSignal;
        return s != null ? s : new Sig(REG_STATUS_NONE, -1, "модем ещё не опрашивали");
    }

    /** Сколько ждать опрос модема, прежде чем считать это ненормальным и записать в лог. */
    static final int SLOW_POLL_WARN_MS = 5000;
    /** То же для записи в сокет подписчика — там нормой являются единицы миллисекунд. */

    /**
     * Единственное место, где происходит блокирующий разговор с модемом.
     *
     * Пока идёт подъём, в AT-порт не лезем вовсе: `wwan-up.sh` на стадии «SIM и регистрация
     * в сети» разговаривает с тем же `/dev/ttyUSB1`, и до этой правки мы ходили туда
     * одновременно с ним, без какой-либо координации (2026-08-12: подъём держал порт
     * 16:18:18-16:18:24, а мы опрашивали его в 16:18:15 и в 16:18:30). Показывать в это
     * время всё равно нечего — идёт анимация, измерение на провод не уходит.
     */
    static void startPoller() {
        Thread t = new Thread(new Runnable() {
            public void run() {
                while (true) {
                    if (bringUpStage() == null) {
                        long t0 = System.nanoTime();
                        Sig s;
                        try {
                            s = pollModem();
                        } catch (Throwable e) {
                            s = new Sig(REG_NONE, -1, "ошибка опроса: " + e);
                        }
                        if (regOverride >= 0) {
                            s = new Sig(regOverride, s.strength, s.detail + " [--reg]");
                        }
                        cachedSignal = s;
                        long took = (System.nanoTime() - t0) / 1000000L;
                        if (took >= SLOW_POLL_WARN_MS) say("опрос модема занял " + took + " мс");
                    }
                    try {
                        Thread.sleep(MODEM_POLL_MS);
                    } catch (InterruptedException e) { return; }
                }
            }
        }, "poll");
        t.setDaemon(true);
        t.start();
    }

    /**
     * Иконка показывает состояние РАДИО, а не наличие интернета — как на телефоне, где
     * палки есть и до того, как поднялась передача данных. Поэтому ждать ppp0 незачем: как
     * только модем зарегистрировался в сети, палки уже видно, и по ним понятно, что
     * подключение идёт. Крестик остаётся ровно в двух случаях: модема нет совсем или он в
     * сети не зарегистрирован (ищет её, нет SIM, нет покрытия).
     */
    static Sig pollModem() {
        String iface = wanIface();
        boolean linked = iface != null && ifaceHasIpv4(iface);
        // Есть AT-порт — это ppp-модем, и спросить его можно на любой стадии, хоть в
        // середине дозвона. У hilink-модема AT-порта нет, но нужен адрес на интерфейсе:
        // без него до его веб-морды не достучаться.
        String tty = findAtTty();
        if (tty != null) return pollPpp(tty, iface, linked);
        if (linked) return pollHilink(iface);
        return new Sig(REG_STATUS_NONE, -1, iface == null
                ? "модем не найден"
                : "модем ещё не поднят (" + iface + " без адреса)");
    }

    // ------------------------------------------------------------------ ppp: AT-порт

    static Sig pollPpp(String tty, String iface, boolean linked) {
        String stage = linked ? ("линк " + iface) : "линка ещё нет";
        String out = at(tty, "AT+CSQ", "AT+COPS?", "AT+CREG?");
        if (out == null) {
            return new Sig(REG_STATUS_NONE, -1, stage + ", " + tty + " не отвечает");
        }
        // +CREG: <n>,<stat>: 1 — зарегистрирован дома, 5 — в роуминге; 2 — ищет сеть,
        // 0/3/4 — не зарегистрирован. Пока ищет — палки рисовать нечестно.
        int creg = -1;
        java.util.regex.Matcher mreg = CREG_RE.matcher(out);
        if (mreg.find()) {
            try { creg = Integer.parseInt(mreg.group(1)); } catch (NumberFormatException ignored) { }
        }
        if (creg == 0 || creg == 2 || creg == 3 || creg == 4) {
            return new Sig(REG_STATUS_NONE, -1, stage + ", модем в сети не зарегистрирован (CREG "
                    + creg + (creg == 2 ? ", ищет сеть" : "") + ")");
        }
        String oper = "";
        int rat = -1;
        java.util.regex.Matcher mc = COPS_RE.matcher(out);
        if (mc.find()) {
            oper = mc.group(1);
            try { rat = Integer.parseInt(mc.group(2)); } catch (NumberFormatException ignored) { }
        }
        int csq = -1;
        java.util.regex.Matcher m = CSQ_RE.matcher(out);
        if (m.find()) {
            try { csq = Integer.parseInt(m.group(1)); } catch (NumberFormatException ignored) { }
        }
        String gen = copsGeneration(rat);
        String who = (oper.isEmpty() ? "" : oper + " ") + (gen == null ? "тип сети неизвестен" : gen);
        if (csq < 0 || csq == 99) {
            return new Sig(genToReg(gen), STRENGTH_WHEN_UNKNOWN,
                    stage + ", CSQ неизвестен (" + csq + "), " + who);
        }
        return new Sig(genToReg(gen), csqToStrength(csq),
                stage + ", CSQ " + csq + " на " + tty + ", " + who, true);
    }

    /**
     * Поколение сети -> celluarRegisterStatus.
     *
     * Шлём НАСТОЯЩИЙ код поколения (1/3/6/10) — это сырой celluarRegisterStatus, который читатель
     * (Toolbox-твик «Статус сети») сам прогоняет через свой switch (mapSystem: 1→2G, 3→3G, 6→4G,
     * 10→5G) и рисует нужный drawable напрямую. В прошивке (разбор SeresSystemUI: таблица drawable
     * в IconManager по слоту status_bar_phone_signal_system) есть картинки на все четыре поколения
     * (status_bar_ic_signal_2g/3g/4g/5g), поэтому слать всегда 6 — значит показывать 4G на 2G/3G/5G.
     * Ровно этот баг наблюдался вживую: модем в 2G, иконка «4G» (ota_02, 2026-08-21).
     *
     * Историческая оговорка: раньше здесь всё схлопывалось в 6, потому что на СТАРОМ, нативном пути
     * (SOME/IP → SSBSignalPolicy.c()) у коллеги с E173s-1 (чистый 3G, AcT=2 → reg=3) иконки не было,
     * и 3G сочли «не рисующимся». Но текущий путь — direct-draw через сам твик, а не c(); там reg
     * маппится в state и рисуется из подтверждённой таблицы drawable. Проверить любое значение на
     * железе: `tbox-icon.sh fake 4 --reg 1|3|6|10`.
     */
    static int genToReg(String gen) {
        if (gen == null) return REG_STATUS_REGISTERED;   // тип не выяснили, но модем в сети -> 4G-заглушка
        switch (gen) {
            case "нет сети": return REG_NONE;
            case "2G":       return REG_2G;
            case "3G":       return REG_3G;
            case "4G":       return REG_4G;
            case "5G":       return REG_5G;
            default:         return REG_STATUS_REGISTERED;
        }
    }

    /** CSQ 0..31 (99 = неизвестно) -> 0..5. RSSI(dBm) = -113 + 2*CSQ. */
    static int csqToStrength(int csq) {
        if (csq >= 20) return 5;
        if (csq >= 15) return 4;
        if (csq >= 11) return 3;
        if (csq >= 8) return 2;
        if (csq >= 4) return 1;
        return 0;
    }

    /** Access technology из +COPS? (3GPP TS 27.007) -> поколение сети. */
    static String copsGeneration(int act) {
        switch (act) {
        case 0: case 1: case 3: return "2G";      // GSM, GSM Compact, GSM/EGPRS
        case 2: case 4: case 5: case 6: return "3G";  // UTRAN и его HSxPA-варианты
        case 7: case 8: return "4G";              // E-UTRAN
        case 11: case 12: case 13: return "5G";   // NR
        default: return null;
        }
    }

    /**
     * Управляющий AT-порт.
     *
     * Порядок: сначала то, что реально нашёл `wwan-up.sh` и положил в state/at-tty —
     * он перебирает все ttyUSB и оставляет тот, что действительно ответил. Только если
     * файла нет (иконку запустили раньше первого подъёма), гадаем сами: сперва
     * bInterfaceProtocol == 12, потом запасной список. Гадание ненадёжно: старые свистки
     * вроде E173 (12d1:1c05) держат 0xFF у всех интерфейсов, и протокола 12 у них нет.
     */
    static String findAtTty() {
        String known = readFirstLine(new java.io.File(wwanDir, "state/at-tty").getPath());
        if (known != null) {
            known = known.trim();
            if (known.length() > 0 && new java.io.File(known).exists()) return known;
        }
        java.io.File[] devs = new java.io.File("/sys/bus/usb/devices").listFiles();
        if (devs != null) {
            for (java.io.File dev : devs) {
                if (dev.getName().indexOf(':') < 0) continue;   // корневые устройства пропускаем
                String proto = readFirstLine(new java.io.File(dev, "bInterfaceProtocol").getPath());
                if (proto == null || !proto.trim().equals("12")) continue;
                java.io.File[] kids = dev.listFiles();
                if (kids == null) continue;
                for (java.io.File kid : kids) {
                    if (kid.getName().startsWith("ttyUSB")) {
                        java.io.File node = new java.io.File("/dev/" + kid.getName());
                        if (node.exists()) return node.getPath();
                    }
                }
            }
        }
        // Запасной список перебираем не «какой существует», а «какой отвечает»: порт
        // может быть на месте и при этом молчать — ровно так ведёт себя ttyUSB1 у E173.
        String firstPresent = null;
        for (String cand : FALLBACK_AT_TTYS) {
            if (!new java.io.File(cand).exists()) continue;
            if (firstPresent == null) firstPresent = cand;
            String r = at(cand, "AT");
            if (r != null && r.toUpperCase(java.util.Locale.US).indexOf("OK") >= 0) return cand;
        }
        // Никто не ответил — отдаём хоть что-то существующее, чтобы вызывающий доложил
        // «порт не отвечает» с конкретным именем, а не молчаливым null.
        return firstPresent;
    }

    /** AT-обмен через wwan/at.sh — там уже решены грабли с ctty и SIGTTIN. */
    static String at(String tty, String... cmds) {
        java.io.File atSh = new java.io.File(wwanDir, "at.sh");
        if (atSh.isFile()) {
            String[] argv = new String[cmds.length + 3];
            argv[0] = "sh"; argv[1] = atSh.getPath(); argv[2] = tty;
            System.arraycopy(cmds, 0, argv, 3, cmds.length);
            return sh(argv, 4000 + 2500 * cmds.length);
        }
        // Тот же обмен, что в at.sh, если файла рядом не оказалось. Подоболочка и
        // timeout --foreground обязательны: чтение из фоновой группы процессов иначе
        // встаёт на SIGTTIN навсегда.
        StringBuilder cmd = new StringBuilder();
        cmd.append("stty -F ").append(tty).append(" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1; ");
        cmd.append("( exec 9<>").append(tty).append(" || exit 1; ");
        cmd.append("  timeout --foreground 1 cat <&9 >/dev/null 2>&1; ");
        for (String c : cmds) {
            cmd.append("  printf '").append(c).append("\\r' >&9; ");
            cmd.append("  timeout --foreground 2 cat <&9 | tr -d '\\r'; ");
        }
        cmd.append(")");
        return sh(new String[] { "sh", "-c", cmd.toString() }, 4000 + 2500 * cmds.length);
    }

    // ------------------------------------------------------------------ hilink: веб-API
    //
    // HiLink-модем — сам себе роутер, и он же сам себе веб-морда. Цифры, которые она
    // показывает, доступны без авторизации обычным GET'ом на шлюз:
    //   Huawei: /api/monitoring/status (на части прошивок /api/monitor/status) —
    //           XML, <SignalIcon>0..5</SignalIcon> и
    //           <CurrentNetworkType>19</CurrentNetworkType> (19 = LTE);
    //   ZTE:    /goform/goform_get_cmd_process?multi_data=1&cmd=signalbar,network_type —
    //           JSON, но только с заголовком Referer на сам модем, иначе 403/пусто.
    // Какой из двух — не гадаем по вендору, а просто пробуем оба и запоминаем удачный.

    static String hilinkFlavor = null;   // "huawei" | "zte" | "none"

    // Сколько подряд неудачных опросов веб-морды терпим, прежде чем честно сказать «нет сети».
    // Линк (адрес на eth1) может пережить пропажу радио/самого модема — DHCP-адрес остаётся, а
    // веб-API уже мёртв; без этого счётчика pollHilink вечно репортил REG_STATUS_REGISTERED (4G,
    // середина палок) и иконка застревала на «успехе» при выдернутом/зависшем модеме. Первые
    // GRACE опросов держим «неизвестно» (не мигаем на разовой заминке), дальше — крестик.
    static final int HILINK_GRACE = 2;   // ~2 такта опроса (MODEM_POLL_MS) ≈ 10 c
    static int hilinkMisses = 0;

    static Sig pollHilink(String iface) {
        String gw = gwOverride != null ? gwOverride : gatewayFor(iface);
        if (gw == null) {
            return hilinkMiss("линк " + iface + ", шлюз модема не определён");
        }
        if (!"zte".equals(hilinkFlavor)) {
            Sig s = pollHuawei(gw, iface);
            if (s != null) { hilinkFlavor = "huawei"; hilinkMisses = 0; return s; }
        }
        if (!"huawei".equals(hilinkFlavor)) {
            Sig s = pollZte(gw, iface);
            if (s != null) { hilinkFlavor = "zte"; hilinkMisses = 0; return s; }
        }
        hilinkFlavor = null;   // на следующем круге пробуем оба заново
        return hilinkMiss("линк " + iface + ", веб-API модема на " + gw + " не ответило");
    }

    /**
     * Модем есть (линк живой), но подтвердить сигнал по веб-API не удалось. Разовую заминку веб-
     * морды не показываем крестиком (держим «неизвестно/середину»), но если API не отвечает
     * HILINK_GRACE опросов подряд — репортим отсутствие сети, а не застывший «успех».
     */
    static Sig hilinkMiss(String why) {
        hilinkMisses++;
        if (hilinkMisses <= HILINK_GRACE) {
            return new Sig(REG_STATUS_REGISTERED, STRENGTH_WHEN_UNKNOWN,
                    why + " (попытка " + hilinkMisses + "/" + HILINK_GRACE + ")");
        }
        return new Sig(REG_NONE, -1, why + " (" + hilinkMisses + " опросов подряд → нет сети)");
    }

    /**
     * Статус у Huawei лежит по одному из двух путей, и какой именно — зависит от прошивки,
     * по вендору не угадать. Web-ui самих модемов зовёт /api/monitoring/status; короткий
     * /api/monitor/status на E8278 (21.261.67.00.778) отвечает ошибкой 100002 «no support».
     * Пробуем по очереди, первый ответивший и есть наш. Найдено автором PR #1 на живом
     * E8278 — у нас такого модема нет, проверить локально нечем.
     */
    static final String[] HUAWEI_STATUS = {
            "/api/monitoring/status",
            "/api/monitor/status",
    };

    /** @return null, если это не Huawei-API (тогда пробуем следующий). */
    static Sig pollHuawei(String gw, String iface) {
        String body = null;
        String path = null;
        for (int i = 0; i < HUAWEI_STATUS.length; i++) {
            String b = httpGet("http://" + gw + HUAWEI_STATUS[i], gw);
            if (b != null && b.indexOf("SignalIcon") >= 0) {
                body = b;
                path = HUAWEI_STATUS[i];
                break;
            }
        }
        if (body == null) return null;
        int bars = intOr(xmlTag(body, "SignalIcon"), -1);
        int netType = intOr(xmlTag(body, "CurrentNetworkType"), -1);
        String gen = huaweiGeneration(netType);
        String rat = gen == null ? ("тип сети неизвестен (CurrentNetworkType " + netType + ")") : gen;
        if (bars < 0) return new Sig(genToReg(gen), STRENGTH_WHEN_UNKNOWN,
                "линк " + iface + ", Huawei API без SignalIcon, " + rat);
        return new Sig(bars > 0 ? genToReg(gen) : REG_NONE, clampBars(bars),
                "линк " + iface + ", Huawei API " + gw + path + ": " + bars + "/5, " + rat, true);
    }

    /** @return null, если это не ZTE-API. */
    static Sig pollZte(String gw, String iface) {
        String body = httpGet("http://" + gw
                + "/goform/goform_get_cmd_process?multi_data=1&cmd=signalbar,network_type,rssi,rsrp,ppp_status",
                gw);
        if (body == null || body.indexOf("signalbar") < 0) return null;
        int bars = intOr(jsonVal(body, "signalbar"), -1);
        String netType = jsonVal(body, "network_type");
        String rssi = jsonVal(body, "rssi");
        String gen = zteGeneration(netType);
        String rat = netType == null ? "тип сети неизвестен" : netType;
        if (bars < 0) return new Sig(genToReg(gen), STRENGTH_WHEN_UNKNOWN,
                "линк " + iface + ", ZTE API без signalbar, " + rat);
        return new Sig(bars > 0 ? genToReg(gen) : REG_NONE, clampBars(bars),
                "линк " + iface + ", ZTE API " + gw + ": " + bars + "/5, " + rat
                        + (rssi == null ? "" : ", rssi " + rssi), true);
    }

    /** CurrentNetworkType из Huawei-API (значения из их же web-ui). */
    static String huaweiGeneration(int t) {
        switch (t) {
        case 0: return "нет сети";
        case 1: case 2: case 3: return "2G";
        case 4: case 5: case 6: case 7: case 8: case 9: case 10: return "3G";
        case 19: case 20: case 21: case 22: case 23: case 24: return "4G";
        case 101: case 102: return "5G";
        default: return null;
        }
    }

    /** network_type у ZTE — строка вида "LTE", "HSPA+", "GSM", "NR5G", "Limited Service". */
    static String zteGeneration(String t) {
        if (t == null) return null;
        String s = t.toUpperCase();
        if (s.indexOf("NR") >= 0 || s.indexOf("5G") >= 0) return "5G";
        if (s.indexOf("LTE") >= 0 || s.indexOf("4G") >= 0) return "4G";
        if (s.indexOf("HSPA") >= 0 || s.indexOf("UMTS") >= 0 || s.indexOf("WCDMA") >= 0
                || s.indexOf("HSDPA") >= 0 || s.indexOf("HSUPA") >= 0 || s.indexOf("3G") >= 0) return "3G";
        if (s.indexOf("GSM") >= 0 || s.indexOf("EDGE") >= 0 || s.indexOf("GPRS") >= 0
                || s.indexOf("2G") >= 0) return "2G";
        // "No Service", "Limited Service", пустая строка — сети нет.
        return "нет сети";
    }

    static int clampBars(int b) { return b < 0 ? 0 : b > 5 ? 5 : b; }

    /**
     * Шлюз модема: сначала default-маршрут через этот интерфейс в любой таблице
     * (wwan-up.sh кладёт его в таблицу 99), иначе — .1 своей же подсети: у HiLink-модемов
     * это всегда так.
     */
    static String gatewayFor(String iface) {
        String routes = sh(new String[] { "ip", "route", "show", "table", "all" }, 4000);
        if (routes != null) {
            java.util.regex.Matcher m = java.util.regex.Pattern.compile(
                    "default via ([0-9.]+) dev " + java.util.regex.Pattern.quote(iface)).matcher(routes);
            if (m.find()) return m.group(1);
        }
        String addr = sh(new String[] { "ip", "-4", "-o", "addr", "show", iface }, 4000);
        if (addr != null) {
            java.util.regex.Matcher m = java.util.regex.Pattern.compile("inet ([0-9.]+)").matcher(addr);
            if (m.find()) return m.group(1).replaceAll("\\.[0-9]+$", ".1");
        }
        return null;
    }

    /** GET без авторизации; Referer нужен ZTE, Huawei он не мешает. */
    static String httpGet(String url, String gw) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(HTTP_TIMEOUT_MS);
            c.setReadTimeout(HTTP_TIMEOUT_MS);
            c.setRequestProperty("Referer", "http://" + gw + "/");
            c.setRequestProperty("Accept", "*/*");
            if (c.getResponseCode() != 200) return null;
            java.io.BufferedReader br = new java.io.BufferedReader(
                    new java.io.InputStreamReader(c.getInputStream(), "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) sb.append(line);
            br.close();
            return sb.toString();
        } catch (Throwable t) {
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    static String xmlTag(String body, String tag) {
        java.util.regex.Matcher m = java.util.regex.Pattern.compile(
                "<" + tag + ">([^<]*)</" + tag + ">").matcher(body);
        return m.find() ? m.group(1).trim() : null;
    }

    static String jsonVal(String body, String key) {
        java.util.regex.Matcher m = java.util.regex.Pattern.compile(
                "\"" + key + "\"\\s*:\\s*\"?([^\",}]*)\"?").matcher(body);
        return m.find() ? m.group(1).trim() : null;
    }

    static int intOr(String s, int dflt) {
        if (s == null) return dflt;
        try { return Integer.parseInt(s.trim()); } catch (NumberFormatException e) { return dflt; }
    }

    // ------------------------------------------------------------------ общее

    static String wanIface() {
        String s = readFirstLine(wwanDir + "/state/wan-iface");
        if (s != null && !s.trim().isEmpty()) return s.trim();
        for (String cand : new String[] { "ppp0", "eth1", "usb0" }) {
            if (new java.io.File("/sys/class/net/" + cand).exists()) return cand;
        }
        return null;
    }

    static boolean ifaceHasIpv4(String iface) {
        String out = sh(new String[] { "ip", "-4", "-o", "addr", "show", iface }, 4000);
        return out != null && out.contains("inet ");
    }

    /** --signal: один опрос со всеми потрохами. Нужен, когда отлаживаешь новый модем. */
    static void dumpSignal() {
        String iface = wanIface();
        String tty = findAtTty();
        say("wwan-dir:  " + wwanDir);
        say("WAN-iface: " + iface + (iface == null ? "" : (ifaceHasIpv4(iface) ? " (адрес есть)" : " (БЕЗ адреса)")));
        say("AT-порт:   " + (tty == null ? "нет (значит hilink)" : tty));
        if (tty == null && iface != null) {
            String gw = gwOverride != null ? gwOverride : gatewayFor(iface);
            say("шлюз модема: " + gw);
            if (gw != null) {
                for (int i = 0; i < HUAWEI_STATUS.length; i++) {
                    String h = httpGet("http://" + gw + HUAWEI_STATUS[i], gw);
                    say("Huawei " + HUAWEI_STATUS[i] + ": " + (h == null ? "нет ответа" : h));
                }
                String z = httpGet("http://" + gw
                        + "/goform/goform_get_cmd_process?multi_data=1&cmd=signalbar,network_type,rssi,rsrp,ppp_status", gw);
                say("ZTE /goform/...: " + (z == null ? "нет ответа" : z));
            }
        } else if (tty != null) {
            say("ответ модема:\n" + at(tty, "AT+CSQ", "AT+COPS?", "AT+CREG?"));
        }
        Sig s = pollModemSafe();
        say("ИТОГ: reg=" + s.reg + " strength=" + s.strength + "  (" + s.detail + ")");
    }

    static Sig pollModemSafe() {
        try { return pollModem(); }
        catch (Throwable t) { return new Sig(REG_STATUS_NONE, -1, "ошибка опроса: " + t); }
    }

    // ------------------------------------------------------------------ «идёт подключение»
    //
    // Отдельной картинки «поиск сети» у головы нет: SeresStatusBarSignalPolicy умеет только
    // крестик и палки поверх значка поколения. А подъём модема после перезагрузки занимает
    // до минуты с лишним (модули, modeswitch, регистрация, дозвон), и всё это время крестик
    // неотличим от «модема нет вообще». Поэтому, пока wwan-up.sh работает, а радио ещё не
    // зарегистрировалось, палки гоняются по кругу 0→4 — как «поиск сети» на телефоне.
    //
    // Живость подъёма берётся из state/busy (его пишет stage() в wwan-up.sh): первое слово —
    // pid, дальше название стадии. Сверяем cmdline, потому что файл переживает и падение
    // скрипта, и перезагрузку: без этого анимация осталась бы навсегда, обещая подключение,
    // которого никто не делает. Умер скрипт — со следующего же уведомления честный крестик.

    /**
     * Идут ли прямо сейчас проверки приложения перед подъёмом.
     *
     * Это стадия ДО wwan-up.sh: BootService дождался adbd, сверяет и раскладывает файлы,
     * потом ждёт 45 секунд «пока система догрузится» (WWAN_BOOT_DELAY в wwan-boot.sh).
     * Минута с лишним, в которую никто ничего не поднимает и показывать нечего, а
     * пользователю важно видеть, что автозапуск не забыл про него. Признак пишет само
     * приложение (state/appboot: 1 — идут проверки, 0 — уже запустило подъём).
     *
     * Здесь возраст файла, а не pid: писатель — процесс приложения, который живёт и после
     * того, как проверки кончились, так что по нему судить не о чем. Возраст страхует от
     * файла с единицей, оставшегося от упавшего приложения; окно щедрое, но это всё равно
     * потолок, а не ожидаемая длительность — нормально признак снимается явно.
     */
    static final long APPBOOT_MAX_AGE_MS = 5 * 60 * 1000;

    static boolean appChecking() {
        java.io.File f = new java.io.File(wwanDir + "/state/appboot");
        if (!f.isFile()) return false;
        if (System.currentTimeMillis() - f.lastModified() > APPBOOT_MAX_AGE_MS) return false;
        String s = readFirstLine(f.getPath());
        return s != null && s.trim().startsWith("1");
    }

    /** Название текущей стадии подъёма, или null, если прямо сейчас никто ничего не поднимает. */
    static String bringUpStage() {
        String s = readFirstLine(wwanDir + "/state/busy");
        if (s == null) return null;
        s = s.trim();
        int sp = s.indexOf(' ');
        String pid = sp < 0 ? s : s.substring(0, sp);
        if (!pid.matches("[1-9]\\d*")) return null;
        String cmdline = readFirstLine("/proc/" + pid + "/cmdline");
        if (cmdline == null || cmdline.indexOf("wwan-up") < 0) return null;
        return sp < 0 ? "подъём" : s.substring(sp + 1);
    }

    /** Сколько палок показать на этом такте анимации: 0,1,2,3,4 и снова 0. */
    static int connectingStrength(int tick) {
        return tick % 5;
    }

    static String readFirstLine(String path) {
        java.io.BufferedReader br = null;
        try {
            br = new java.io.BufferedReader(new java.io.FileReader(path));
            return br.readLine();
        } catch (Exception e) {
            return null;
        } finally {
            if (br != null) try { br.close(); } catch (Exception ignored) { }
        }
    }

    /** Запуск команды с мягким таймаутом: читаем вывод в отдельном потоке и join'им его. */
    static String sh(String[] argv, int timeoutMs) {
        Process p = null;
        try {
            ProcessBuilder pb = new ProcessBuilder(argv);
            pb.redirectErrorStream(true);
            p = pb.start();
            final Process proc = p;
            final StringBuilder sb = new StringBuilder();
            Thread reader = new Thread(new Runnable() {
                public void run() {
                    java.io.BufferedReader br = new java.io.BufferedReader(
                            new java.io.InputStreamReader(proc.getInputStream()));
                    try {
                        String line;
                        while ((line = br.readLine()) != null) sb.append(line).append('\n');
                    } catch (Exception ignored) { }
                }
            });
            reader.setDaemon(true);
            reader.start();
            reader.join(timeoutMs);
            p.destroy();
            return sb.toString();
        } catch (Throwable t) {
            return null;
        } finally {
            if (p != null) p.destroy();
        }
    }

    // ------------------------------------------------------------------------- мелочи

    static int putShort(byte[] b, int o, int v) { b[o] = (byte) (v >> 8); b[o + 1] = (byte) v; return o + 2; }
    static int putInt(byte[] b, int o, int v) {
        b[o] = (byte) (v >> 24); b[o + 1] = (byte) (v >> 16);
        b[o + 2] = (byte) (v >> 8); b[o + 3] = (byte) v; return o + 4;
    }
    static int readShort(byte[] b, int o) { return ((b[o] & 0xff) << 8) | (b[o + 1] & 0xff); }
    static int readInt(byte[] b, int o) {
        return ((b[o] & 0xff) << 24) | ((b[o + 1] & 0xff) << 16) | ((b[o + 2] & 0xff) << 8) | (b[o + 3] & 0xff);
    }

    static void parseArgs(String[] a) {
        for (int i = 0; i < a.length; i++) {
            String s = a[i];
            if ("--notify-ms".equals(s)) notifyMs = Integer.parseInt(a[++i]);
            else if ("--strength".equals(s)) fixedStrength = Integer.parseInt(a[++i]);
            else if ("--wwan-dir".equals(s)) wwanDir = a[++i];
            else if ("--gw".equals(s)) gwOverride = a[++i];
            else if ("--reg".equals(s)) regOverride = Integer.parseInt(a[++i]);
            else if ("--signal".equals(s)) signalOnly = true;
            else if ("--signal-file".equals(s)) signalFile = a[++i];
            else throw new IllegalArgumentException("неизвестный аргумент: " + s);
        }
    }
}
