package su.dsr.f515usbwwan;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;

/**
 * Автозапуск после перезагрузки головы: дождаться adbd, разложить файлы и отцепленно
 * стартовать wwan-boot.sh (тот уже сам защищается от бутлупа и дальше сторожит связь).
 *
 * Foreground-сервис, а не обычный: Android 10 не даёт фоновому приложению поднять
 * простой сервис, а работа тут длинная - ожидание adbd с нарастающей паузой занимает
 * до нескольких минут. Уведомление снимается сразу по завершении.
 */
public class BootService extends Service {

    /**
     * Всё, что пишется отсюда, идёт уровнем W намеренно. На этой голове стоит
     * `persist.log.tag=W`, то есть Log.i из обычного приложения logcat выбрасывает молча -
     * и разбор «почему после ребута сеть не поднялась» превращается в гадание: службы уже
     * нет, следов нет. Уровень W ничего не стоит (две-три строки на загрузку), зато делает
     * автозапуск наблюдаемым без `setprop log.tag.f515usbwwan V` на живой голове.
     */
    private static final String TAG = "f515usbwwan";
    private static final String CHANNEL = "wwan-boot";
    private static final int NOTIFICATION_ID = 1;
    /** Сколько всего ждать adbd (опрашивая раз в секунду), прежде чем сдаться. */
    private static final long ADB_BUDGET_MS = 8 * 60 * 1000;

    private static volatile boolean running = false;
    /**
     * После ребута прилетает два броадкаста подряд (LOCKED_BOOT_COMPLETED, следом
     * BOOT_COMPLETED). Первый заход обычно успевает закончиться за пару секунд, поэтому
     * одного признака "сейчас работает" мало - второй броадкаст запускал всю процедуру
     * заново, и на стенде после ребута оставалось два сторожа. Этот признак живёт до
     * конца жизни процесса, то есть до следующей загрузки.
     */
    private static volatile boolean alreadyRan = false;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION_ID, notification("Поднимаю USB-модем после перезагрузки"));

        synchronized (BootService.class) {
            if (running || alreadyRan) {
                Log.w(TAG, "boot: заход уже был в этой загрузке, второй не нужен");
                stopForeground(true);
                stopSelf();
                return START_NOT_STICKY;
            }
            running = true;
            alreadyRan = true;
        }

        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    if (!Autostart.isEnabled(BootService.this)) {
                        Log.w(TAG, "boot: автозапуск выключен, выхожу");
                        return;
                    }
                    String out = Keeper.bootAutostart(BootService.this, ADB_BUDGET_MS,
                            new Keeper.Progress() {
                                @Override
                                public void onLine(String line) {
                                    Log.w(TAG, "boot: " + line);
                                }
                            });
                    Log.w(TAG, "boot: готово\n" + out);
                } catch (Throwable t) {
                    Log.e(TAG, "boot: сорвалось", t);
                } finally {
                    running = false;
                    stopForeground(true);
                    stopSelf();
                }
            }
        }, "wwan-boot").start();

        return START_NOT_STICKY;
    }

    private Notification notification(String text) {
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Автозапуск модема",
                NotificationManager.IMPORTANCE_LOW);
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);
        return new Notification.Builder(this, CHANNEL)
                .setContentTitle("F515 USB WWAN")
                .setContentText(text)
                // Иконка из фреймворка, а не своя: R.java при этой сборке (aapt2 без
                // --java) не генерируется, ссылаться на собственный ресурс из кода нечем.
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .build();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
