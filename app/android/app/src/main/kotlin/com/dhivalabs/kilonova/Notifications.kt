package com.dhivalabs.kilonova

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal const val PAYMENTS_CHANNEL = "payments"

/// The channel of the keep-alive service that background checks replaced.
private const val OLD_SYNC_CHANNEL = "background_sync"

/// Payment notifications, the notification permission, and background
/// checks for the wallets the owner chose (see BackgroundChecks.kt). Must be
/// created while the activity is being constructed, because it registers
/// for the permission result.
class NotificationsChannel(private val activity: FragmentActivity) : MethodChannel.MethodCallHandler {
    private var pendingPermission: MethodChannel.Result? = null

    private val permission =
        activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            pendingPermission?.success(granted && canNotify(activity))
            pendingPermission = null
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notify" -> {
                createChannels(activity)
                notifyPayment(
                    activity,
                    call.argument<Int>("id") ?: 0,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                    call.argument<String>("publicTitle") ?: "",
                )
                result.success(null)
            }
            "pushWallet" -> {
                rememberPushWallet(
                    activity,
                    call.argument<String>("instance") ?: "",
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                )
                result.success(null)
            }
            "pushAnnouncing" -> {
                announcingWallets = call.argument<List<String>>("instances")?.toSet() ?: emptySet()
                result.success(null)
            }
            "pushWalletRemoved" -> {
                forgetPushWallet(activity, call.argument<String>("instance") ?: "")
                result.success(null)
            }
            "canNotify" -> result.success(canNotify(activity))
            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT < 33 || canNotify(activity)) {
                    result.success(canNotify(activity))
                } else if (pendingPermission != null) {
                    result.error("busy", "already asking", null)
                } else {
                    pendingPermission = result
                    permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
            "batteryUnrestricted" -> {
                val power = activity.getSystemService(PowerManager::class.java)
                result.success(power?.isIgnoringBatteryOptimizations(activity.packageName) == true)
            }
            "openBatterySettings" -> {
                // The list of apps, where the owner picks Kilonova. Asking
                // directly (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) is
                // restricted by Play policy.
                try {
                    activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    result.success(true)
                } catch (_: ActivityNotFoundException) {
                    result.success(false)
                }
            }
            "checkWallets" -> result.success(WatchStore.ids(activity))
            "checkWallet" -> {
                val id = call.argument<String>("id")
                val state = call.argument<ByteArray>("state")
                val dir = call.argument<String>("dir")
                if (id == null || state == null || dir == null) {
                    result.error("bad_request", "id, state and dir are needed", null)
                    return
                }
                try {
                    WatchStore.save(activity, id, state)
                } catch (e: Exception) {
                    result.error("storage", e.javaClass.simpleName, null)
                    return
                } finally {
                    state.fill(0)
                }
                BackgroundChecks.rememberDir(activity, dir)
                BackgroundChecks.schedule(activity)
                result.success(null)
            }
            "checkLabels" -> {
                val labels = call.argument<Map<String, Map<String, String>>>("wallets") ?: emptyMap()
                BackgroundChecks.rememberLabels(
                    activity,
                    labels,
                    call.argument<String>("publicTitle") ?: "",
                )
                result.success(null)
            }
            "stopChecking" -> {
                WatchStore.remove(activity, call.argument<String>("id") ?: "")
                result.success(null)
            }
            "stopCheckingAll" -> {
                WatchStore.clear(activity)
                result.success(null)
            }
            "checkNow" -> {
                BackgroundChecks.runOnce(activity)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

internal fun canNotify(context: Context): Boolean =
    Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
        PackageManager.PERMISSION_GRANTED

internal fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
    context,
    0,
    Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
    PendingIntent.FLAG_IMMUTABLE,
)

internal fun createChannels(context: Context) {
    if (Build.VERSION.SDK_INT < 26) return
    val manager = context.getSystemService(NotificationManager::class.java)
    manager.createNotificationChannel(
        NotificationChannel(PAYMENTS_CHANNEL, "Payments", NotificationManager.IMPORTANCE_DEFAULT),
    )
    manager.deleteNotificationChannel(OLD_SYNC_CHANNEL)
}

/// Shows a payment notification. The lock screen shows only
/// [publicTitle], never the amount or the wallet.
internal fun notifyPayment(context: Context, id: Int, title: String, body: String, publicTitle: String) {
    if (!canNotify(context)) return
    val public = NotificationCompat.Builder(context, PAYMENTS_CHANNEL)
        .setSmallIcon(R.drawable.ic_stat_kilonova)
        .setContentTitle(publicTitle)
        .build()
    val notification = NotificationCompat.Builder(context, PAYMENTS_CHANNEL)
        .setSmallIcon(R.drawable.ic_stat_kilonova)
        .setContentTitle(title)
        .setContentText(body)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .setPublicVersion(public)
        .setContentIntent(openApp(context))
        .setAutoCancel(true)
        .build()
    try {
        NotificationManagerCompat.from(context).notify(id, notification)
    } catch (_: SecurityException) {
        // Permission withdrawn in the meantime.
    }
}
