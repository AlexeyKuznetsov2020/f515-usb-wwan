package su.dsr.f515usbwwan;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Ловит загрузку системы и передаёт работу BootService.
 *
 * Сам ничего не делает: у receiver'а ~10 секунд, а тут нужно дождаться adbd (может
 * занять минуты), поэтому единственная задача - стартовать foreground-сервис.
 * Приходить может дважды (LOCKED_BOOT_COMPLETED и следом BOOT_COMPLETED) - повторный
 * запуск безвреден, BootService сам не делает второй заход, если уже работает.
 */
public class BootReceiver extends BroadcastReceiver {

    private static final String TAG = "f515usbwwan";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_LOCKED_BOOT_COMPLETED.equals(action)) {
            return;
        }
        if (!Autostart.isEnabled(context)) {
            Log.i(TAG, "boot: автозапуск выключен в настройках приложения");
            return;
        }
        Log.i(TAG, "boot: " + action + " -> BootService");
        context.startForegroundService(new Intent(context, BootService.class));
    }
}
