package com.dhivalabs.kilonova

import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import org.unifiedpush.android.connector.data.PushMessage
import org.unifiedpush.flutter.connector.UnifiedPushService

private const val PUSH_PREFS = "kilonova_push"

/// Wallets unlocked in this process that announce their own payments, with
/// the amount, once a push makes them sync; set from Dart. Empty when the
/// process starts, as every wallet is then locked.
@Volatile
var announcingWallets: Set<String> = emptySet()

/// Receives payment pushes from the owner's own server through their
/// UnifiedPush distributor. A push says only that something arrived for a
/// wallet (the instance is the wallet id), so the notification says no
/// more; Kilonova shows the amount once the wallet syncs. Pushes reach the
/// Flutter side too, which syncs the wallet if it is unlocked.
class KilonovaPushService : UnifiedPushService() {
    // With Kilonova closed, nothing in Dart can use a push (every wallet is
    // locked), so no Dart runs: the engine only carries the plugin.
    override fun getEngine(context: Context): FlutterEngine =
        FlutterEngine(context, null, false)

    override fun onMessage(message: PushMessage, instance: String) {
        notifyArrival(this, instance)
        super.onMessage(message, instance)
    }
}

/// Remembers what to show for pushes for [instance], in the owner's
/// language, set by Dart when pushes are turned on for that wallet.
fun rememberPushWallet(context: Context, instance: String, title: String, body: String) {
    context.getSharedPreferences(PUSH_PREFS, Context.MODE_PRIVATE).edit()
        .putString("$instance.title", title)
        .putString("$instance.body", body)
        .apply()
}

fun forgetPushWallet(context: Context, instance: String) {
    context.getSharedPreferences(PUSH_PREFS, Context.MODE_PRIVATE).edit()
        .remove("$instance.title")
        .remove("$instance.body")
        .apply()
}

private fun notifyArrival(context: Context, instance: String) {
    // On screen, the app shows the payment itself once it syncs.
    if (MainActivity.visible || instance in announcingWallets) return
    val prefs = context.getSharedPreferences(PUSH_PREFS, Context.MODE_PRIVATE)
    val title = prefs.getString("$instance.title", null) ?: return
    val body = prefs.getString("$instance.body", null) ?: return
    if (!canNotify(context)) return
    createChannels(context)
    val notification = NotificationCompat.Builder(context, PAYMENTS_CHANNEL)
        .setSmallIcon(R.drawable.ic_stat_kilonova)
        .setContentTitle(title)
        .setContentText(body)
        .setContentIntent(openApp(context))
        .setAutoCancel(true)
        .build()
    try {
        NotificationManagerCompat.from(context).notify(instance.hashCode(), notification)
    } catch (_: SecurityException) {
        // Permission withdrawn in the meantime.
    }
}
