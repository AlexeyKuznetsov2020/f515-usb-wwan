package su.dsr.f515usbwwan;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/**
 * Everything that needs root goes through here: connect to the local adbd (already root
 * on this build), deploy the wwan/ files and run one of the scripts. The scripts
 * themselves are idempotent and self-checking (wwan-up.sh checks every stage's
 * precondition, wwan-boot.sh guards against boot loops), so this class stays deliberately
 * thin - it does not duplicate any of that logic, it just makes sure the files are on the
 * device before running them.
 */
public class Keeper {

    static final String DIR = "/data/local/tmp/wwan";
    static final String UP = DIR + "/wwan-up.sh";
    static final String BOOT = DIR + "/wwan-boot.sh";
    static final String FORMAT = DIR + "/format-sdcard.sh";
    static final String ADB_HOST = "127.0.0.1";
    static final int ADB_PORT = 5555;

    /** 180s: worst case inside wwan-up.sh is modeswitch reconnect (20s) + network
     *  registration (30s) + dial timeout (60s) + margin. */
    private static final int RUN_TIMEOUT_MS = 180000;

    /** name in assets/, path on device, executable bit */
    private static final Object[][] FILES = {
            {"wwan-up.sh", "wwan-up.sh", Boolean.TRUE},
            {"wwan-boot.sh", "wwan-boot.sh", Boolean.TRUE},
            {"dial.sh", "dial.sh", Boolean.TRUE},
            {"at.sh", "at.sh", Boolean.TRUE},
            {"format-sdcard.sh", "format-sdcard.sh", Boolean.TRUE},
            {"huawei-modeswitch", "huawei-modeswitch", Boolean.TRUE},
            {"usbserialmerged2.ko", "usbserialmerged2.ko", Boolean.FALSE},
            {"ppp_async.ko", "ppp_async.ko", Boolean.FALSE},
    };

    private static final Object LOCK = new Object();

    public interface Progress {
        void onLine(String line);
    }

    /** Deploys wwan/ and runs wwan-up.sh with the given arguments (e.g. "--check"). */
    public static String run(Context ctx, String args, Progress progress) {
        return exec(ctx, UP, args, progress);
    }

    /** wwan-boot.sh with the given arguments ("--status", "--reset", "--disable", "--stop"). */
    public static String runBoot(Context ctx, String args, Progress progress) {
        return exec(ctx, BOOT, args, progress);
    }

    /** format-sdcard.sh with the given arguments ("--list" or "--format=sdX"). */
    public static String runFormat(Context ctx, String args, Progress progress) {
        return exec(ctx, FORMAT, args, progress);
    }

    /**
     * Starts wwan-boot.sh detached from this adb session: setsid + closed stdio, so the
     * script (which sleeps, then brings the modem up, then stays as a watchdog) survives
     * the shell channel closing right after this call returns. A plain background job
     * would not - that was verified the hard way on this head unit.
     */
    public static String startAutostart(Context ctx, boolean now, Progress progress) {
        String cmd = "mkdir -p " + DIR + "/state; setsid sh " + BOOT + (now ? " --now" : "")
                + " </dev/null >>" + DIR + "/state/boot-stdout.log 2>&1 & echo started";
        return exec(ctx, null, cmd, progress);
    }

    /**
     * The autostart path (BootService): same as startAutostart, but waits for adbd to
     * come up first - right after a reboot it usually is not listening yet.
     */
    public static String bootAutostart(Context ctx, int attempts, Progress progress) {
        synchronized (LOCK) {
            StringBuilder sb = new StringBuilder();
            AdbClient adb = null;
            try {
                adb = connectWaiting(ctx, attempts, progress);
                String uid = adb.shell("id -u").trim();
                line(progress, sb, "adb connected, uid=" + uid);
                if (!uid.startsWith("0")) {
                    line(progress, sb, "WARNING: adbd is not root, this will fail");
                }
                adb.shell("mkdir -p " + DIR);
                deployMissing(ctx, adb, progress, sb);
                String out = adb.shell("mkdir -p " + DIR + "/state; setsid sh " + BOOT
                        + " </dev/null >>" + DIR + "/state/boot-stdout.log 2>&1 & echo started");
                line(progress, sb, "запуск wwan-boot.sh: " + out.trim());
            } catch (Exception e) {
                line(progress, sb, "автозапуск не состоялся: " + e);
            } finally {
                if (adb != null) adb.close();
            }
            return sb.toString();
        }
    }

    /**
     * Deploys the payload, then runs either a script (script != null, args appended) or a
     * raw shell command (script == null, the command is in args).
     */
    private static String exec(Context ctx, String script, String args, Progress progress) {
        synchronized (LOCK) {
            StringBuilder sb = new StringBuilder();
            AdbClient adb = null;
            try {
                adb = connect(ctx, RUN_TIMEOUT_MS);
                String uid = adb.shell("id -u").trim();
                line(progress, sb, "adb connected, uid=" + uid);
                if (!uid.startsWith("0")) {
                    line(progress, sb, "WARNING: adbd is not root, this will fail");
                }

                adb.shell("mkdir -p " + DIR);
                deployMissing(ctx, adb, progress, sb);

                String cmd = script == null ? args : "sh " + script + " " + args + " 2>&1";
                line(progress, sb, "--- " + cmd + " ---");
                String out = adb.shell(cmd);
                for (String l : out.split("\n")) line(progress, sb, l);
            } catch (Exception e) {
                line(progress, sb, "failed: " + e);
            } finally {
                if (adb != null) adb.close();
            }
            return sb.toString();
        }
    }

    static AdbClient connect(Context ctx, int timeoutMs) throws Exception {
        return new AdbClient(ADB_HOST, ADB_PORT, asset(ctx, "adbkey"), asset(ctx, "adbkey.pub"), timeoutMs);
    }

    /**
     * Same, but for the boot path: right after BOOT_COMPLETED adbd may not be listening on
     * 5555 yet (or may not have loaded adb_keys), so a single attempt is not enough.
     * Waits with a growing delay instead of hammering, and gives up rather than looping
     * forever - if adb never shows up, nothing here can work anyway and the user still has
     * the buttons.
     */
    static AdbClient connectWaiting(Context ctx, int attempts, Progress progress) throws Exception {
        Exception last = null;
        int delayMs = 5000;
        for (int i = 1; i <= attempts; i++) {
            try {
                AdbClient adb = connect(ctx, RUN_TIMEOUT_MS);
                if (progress != null) progress.onLine("adbd доступен с попытки " + i);
                return adb;
            } catch (Exception e) {
                last = e;
                if (progress != null) {
                    progress.onLine("adbd пока недоступен (попытка " + i + "/" + attempts + "): " + e);
                }
                Thread.sleep(delayMs);
                if (delayMs < 30000) delayMs += 5000;
            }
        }
        throw last != null ? last : new java.io.IOException("adbd недоступен");
    }

    /**
     * Pushes only files that are missing or the wrong size (idempotent: pressing any
     * button again after the first run does not re-transfer ~800 KB every time).
     * Uses base64 chunks over the shell channel rather than the sync protocol, since the
     * shell() helper already exists and is proven to work - large payloads are just split
     * into pieces small enough that no single adb message approaches AdbClient's MAXDATA.
     */
    static void deployMissing(Context ctx, AdbClient adb, Progress progress, StringBuilder sb)
            throws Exception {
        for (Object[] f : FILES) {
            String assetName = (String) f[0];
            String remote = DIR + "/" + f[1];
            boolean exec = (Boolean) f[2];

            byte[] data = asset(ctx, assetName);
            String remoteSize = adb.shell("stat -c%s " + remote + " 2>/dev/null || echo 0").trim();
            if (String.valueOf(data.length).equals(remoteSize)) {
                line(progress, sb, "  " + assetName + ": уже на месте (" + data.length + " Б)");
                continue;
            }

            line(progress, sb, "  " + assetName + ": заливаю (" + data.length + " Б)...");
            pushFile(adb, data, remote);

            String newSize = adb.shell("stat -c%s " + remote + " 2>/dev/null || echo -1").trim();
            if (!String.valueOf(data.length).equals(newSize)) {
                throw new java.io.IOException(assetName + ": после заливки размер " + newSize
                        + ", ожидался " + data.length);
            }
            if (exec) adb.shell("chmod 755 " + remote);
            line(progress, sb, "  " + assetName + ": ok");
        }
    }

    private static void pushFile(AdbClient adb, byte[] data, String remote) throws Exception {
        String b64 = android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP);
        String tmp = remote + ".b64";
        adb.shell("rm -f " + tmp);
        // ~48000 base64 chars/chunk keeps each adb shell command comfortably under any
        // adbd service-string limit while still needing only ~20 round trips per MB.
        int chunk = 48000;
        for (int i = 0; i < b64.length(); i += chunk) {
            String part = b64.substring(i, Math.min(b64.length(), i + chunk));
            adb.shell("echo '" + part + "' >> " + tmp);
        }
        String out = adb.shell("base64 -d " + tmp + " > " + remote + " && rm -f " + tmp + " && echo ok").trim();
        if (!out.contains("ok")) {
            throw new java.io.IOException("base64 -d не сработал: " + out);
        }
    }

    private static byte[] asset(Context ctx, String name) throws Exception {
        InputStream is = ctx.getAssets().open(name);
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        } finally {
            is.close();
        }
    }

    private static void line(Progress progress, StringBuilder sb, String text) {
        sb.append(text).append('\n');
        if (progress != null) progress.onLine(text);
    }
}
