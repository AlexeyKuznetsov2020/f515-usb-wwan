package su.dsr.f515usbwwan;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Один-единственный признак «автозапуск разрешён», общий для UI и BootReceiver.
 *
 * Хранится в device-protected storage: приложение объявлено directBootAware, а
 * BOOT_COMPLETED на этой голове может прийти раньше, чем станет доступно обычное
 * (credential-encrypted) хранилище настроек - из него на этом этапе не прочиталось бы
 * ничего, и автозапуск молча считался бы выключенным.
 *
 * Выключено по умолчанию: включать автозапуск должен человек, осознанно, кнопкой.
 * На голове есть свой отдельный, более грубый выключатель - файл state/disabled,
 * который ставит сам wwan-boot.sh, когда подозревает цикл перезагрузок.
 */
public class Autostart {

    private static final String PREFS = "wwan";
    private static final String KEY = "autostart";

    private static SharedPreferences prefs(Context ctx) {
        Context c = ctx.isDeviceProtectedStorage() ? ctx : ctx.createDeviceProtectedStorageContext();
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public static boolean isEnabled(Context ctx) {
        return prefs(ctx).getBoolean(KEY, false);
    }

    public static void setEnabled(Context ctx, boolean enabled) {
        prefs(ctx).edit().putBoolean(KEY, enabled).commit();
    }
}
