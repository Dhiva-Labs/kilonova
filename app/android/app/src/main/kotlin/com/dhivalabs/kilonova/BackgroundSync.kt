package com.dhivalabs.kilonova

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal const val PAYMENTS_CHANNEL = "payments"
private const val SYNC_CHANNEL = "background_sync"
private const val SYNC_NOTIFICATION_ID = 1

/// Keeps the process alive while unlocked wallets sync in the background,
/// and shows payment notifications. Only used when the owner turns on
/// background sync; see the Kilonova privacy policy.
class BackgroundSync(private val activity: FragmentActivity) : MethodChannel.MethodCallHandler {
    init {
        createChannels(activity)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notify" -> {
                notifyPayment(
                    call.argument<Int>("id") ?: 0,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                    call.argument<String>("publicTitle") ?: "",
                )
                result.success(null)
            }
            "startKeepAlive" -> {
                val intent = Intent(activity, SyncService::class.java)
                    .putExtra("title", call.argument<String>("title"))
                    .putExtra("text", call.argument<String>("text"))
                ContextCompat.startForegroundService(activity, intent)
                result.success(null)
            }
            "stopKeepAlive" -> {
                activity.stopService(Intent(activity, SyncService::class.java))
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
            "canNotify" -> result.success(canNotify())
            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT >= 33 && !canNotify()) {
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        0,
                    )
                }
                result.success(canNotify())
            }
            else -> result.notImplemented()
        }
    }

    private fun canNotify(): Boolean = canNotify(activity)

    private fun notifyPayment(id: Int, title: String, body: String, publicTitle: String) {
        if (!canNotify()) return
        // The lock screen shows only that a payment arrived, not the amount.
        val public = NotificationCompat.Builder(activity, PAYMENTS_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_kilonova)
            .setContentTitle(publicTitle)
            .build()
        val notification = NotificationCompat.Builder(activity, PAYMENTS_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_kilonova)
            .setContentTitle(title)
            .setContentText(body)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setContentIntent(openApp(activity))
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(activity).notify(id, notification)
        } catch (_: SecurityException) {
            // Permission withdrawn in the meantime.
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
    manager.createNotificationChannel(
        NotificationChannel(SYNC_CHANNEL, "Background sync", NotificationManager.IMPORTANCE_LOW),
    )
}

/// The foreground service that keeps Kilonova running while it syncs in the
/// background. It does no work itself: sync runs in the Rust core.
class SyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannels(this)
        val notification: Notification = NotificationCompat.Builder(this, SYNC_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_kilonova)
            .setContentTitle(intent?.getStringExtra("title") ?: "Kilonova")
            .setContentText(intent?.getStringExtra("text"))
            .setOngoing(true)
            .setContentIntent(openApp(this))
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(SYNC_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(SYNC_NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    // Android 15 limits data sync services to six hours a day.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }
}
