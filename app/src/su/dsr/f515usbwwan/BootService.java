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

    private static final String TAG = "f515usbwwan";
    private static final String CHANNEL = "wwan-boot";
    private static final int NOTIFICATION_ID = 1;
    /** ~20 попыток с паузой 5..30 с - примерно 8 минут ожидания adbd, дальше сдаёмся. */
    private static final int ADB_ATTEMPTS = 20;

    private static volatile boolean running = false;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION_ID, notification("Поднимаю USB-модем после перезагрузки"));

        synchronized (BootService.class) {
            if (running) {
                Log.i(TAG, "boot: заход уже идёт, второй не нужен");
                return START_NOT_STICKY;
            }
            running = true;
        }

        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    if (!Autostart.isEnabled(BootService.this)) {
                        Log.i(TAG, "boot: автозапуск выключен, выхожу");
                        return;
                    }
                    String out = Keeper.bootAutostart(BootService.this, ADB_ATTEMPTS,
                            new Keeper.Progress() {
                                @Override
                                public void onLine(String line) {
                                    Log.i(TAG, "boot: " + line);
                                }
                            });
                    Log.i(TAG, "boot: готово\n" + out);
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
