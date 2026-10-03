package com.dhivalabs.kilonova

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

private const val TAG = "KilonovaChecks"
private const val PREFS = "kilonova_background_checks"
private const val WORK = "background_checks"
private const val WORK_NOW = "background_checks_now"
private const val FRAME_VERSION: Byte = 1

/// Checks the wallets the owner chose for incoming payments about every 15
/// minutes, with Kilonova closed, through WorkManager. No Flutter engine
/// starts: the worker decrypts each wallet's watch state (view key, never
/// the spend key or seed), hands it to the Rust core and shows what came.
/// Only used after the owner agrees on the consent screen; see the
/// Kilonova privacy policy.
object BackgroundChecks {
    fun schedule(context: Context) {
        val request = PeriodicWorkRequest.Builder(BackgroundScanWorker::class.java, 15, TimeUnit.MINUTES)
            .setConstraints(constraints())
            .build()
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /// One check as soon as the network allows, for trying it out.
    fun runOnce(context: Context) {
        val request = OneTimeWorkRequest.Builder(BackgroundScanWorker::class.java)
            .setConstraints(constraints())
            .build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_NOW, ExistingWorkPolicy.REPLACE, request)
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK)
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NOW)
    }

    private fun constraints() = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    /// The app's wallet directory, whose settings (proxy, node, light
    /// wallet server) the checks follow.
    fun rememberDir(context: Context, dir: String) {
        prefs(context).edit().putString("dir", dir).apply()
    }

    /// What notifications say, in the owner's language, per wallet:
    /// `title`, and `body` and `pending` with `{amount}` in place of the
    /// amount.
    fun rememberLabels(context: Context, wallets: Map<String, Map<String, String>>, publicTitle: String) {
        val edit = prefs(context).edit().clear()
        prefs(context).getString("dir", null)?.let { edit.putString("dir", it) }
        edit.putString("public", publicTitle)
        for ((id, labels) in wallets) {
            for (key in listOf("title", "body", "pending")) {
                labels[key]?.let { edit.putString("$id.$key", it) }
            }
        }
        edit.apply()
    }

    internal fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/// Each chosen wallet's watch state, encrypted with an AES-GCM key that
/// lives in the Android Keystore (in the secure hardware where the device
/// has it) and cannot be exported. The key needs no unlock, so checks run
/// with the phone locked; it is deleted with the last watch state.
internal object WatchStore {
    private const val KEY_ALIAS = "kilonova_background_checks"
    private const val IV_BYTES = 12

    private fun dir(context: Context) = File(context.noBackupFilesDir, "background_checks")

    private fun safe(id: String) = id.filter { it.isLetterOrDigit() || it == '-' || it == '_' }

    private fun file(context: Context, id: String) = File(dir(context), "${safe(id)}.bin")

    fun has(context: Context, id: String) = file(context, id).exists()

    fun ids(context: Context): List<String> =
        dir(context).listFiles()
            ?.filter { it.name.endsWith(".bin") }
            ?.map { it.name.removeSuffix(".bin") }
            ?.sorted()
            ?: emptyList()

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun key(create: Boolean): SecretKey? {
        (keyStore().getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    fun save(context: Context, id: String, state: ByteArray) {
        require(safe(id) == id && id.isNotEmpty()) { "not a wallet id" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        // Bound to the wallet, so one wallet's file copied over another's
        // does not open.
        cipher.updateAAD(id.toByteArray())
        val sealed = cipher.iv + cipher.doFinal(state)
        val target = file(context, id)
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, "${target.name}.tmp")
        temp.writeBytes(sealed)
        if (!temp.renameTo(target)) {
            temp.delete()
            throw java.io.IOException("could not save")
        }
    }

    /// The decrypted watch state; the caller wipes it. `null` if there is
    /// none or it cannot be opened (the key is gone), in which case it is
    /// deleted.
    fun load(context: Context, id: String): ByteArray? {
        val sealed = try {
            file(context, id).readBytes()
        } catch (_: java.io.IOException) {
            return null
        }
        return try {
            val key = key(create = false) ?: throw java.security.GeneralSecurityException("no key")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, IV_BYTES))
            cipher.updateAAD(id.toByteArray())
            cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES)
        } catch (_: java.security.GeneralSecurityException) {
            remove(context, id)
            null
        }
    }

    /// Deletes one wallet's watch state; with none left, the key too, and
    /// checks stop.
    fun remove(context: Context, id: String) {
        file(context, id).delete()
        if (ids(context).isEmpty()) clear(context)
    }

    fun clear(context: Context) {
        dir(context).listFiles()?.forEach { it.delete() }
        dir(context).delete()
        try {
            keyStore().deleteEntry(KEY_ALIAS)
        } catch (_: java.security.KeyStoreException) {
            // Already gone.
        }
        BackgroundChecks.cancel(context)
        BackgroundChecks.prefs(context).edit().clear().apply()
    }
}

/// The Rust core's entry point for checks (kn-ffi, `background.rs`).
object BackgroundScan {
    init {
        System.loadLibrary("kn_ffi")
    }

    @JvmStatic
    external fun scan(input: ByteArray): ByteArray
}

/// One round of checks: every chosen wallet in turn.
class BackgroundScanWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val context = applicationContext
        val ids = WatchStore.ids(context)
        if (ids.isEmpty()) {
            BackgroundChecks.cancel(context)
            return Result.success()
        }
        val prefs = BackgroundChecks.prefs(context)
        val request = JSONObject()
        prefs.getString("dir", null)?.let { request.put("dir", it) }
        val header = request.toString().toByteArray()
        for (id in ids) {
            if (isStopped) break
            val state = WatchStore.load(context, id) ?: continue
            val input = ByteBuffer.allocate(5 + header.size + state.size)
                .order(ByteOrder.LITTLE_ENDIAN)
                .put(FRAME_VERSION)
                .putInt(header.size)
                .put(header)
                .put(state)
                .array()
            state.fill(0)
            val output = try {
                BackgroundScan.scan(input)
            } catch (e: Throwable) {
                Log.w(TAG, "check failed: ${e.javaClass.simpleName}")
                continue
            } finally {
                input.fill(0)
            }
            try {
                handle(context, id, output)
            } finally {
                output.fill(0)
            }
        }
        return Result.success()
    }

    private fun handle(context: Context, id: String, output: ByteArray) {
        if (output.size < 5 || output[0] != FRAME_VERSION) return
        val length = ByteBuffer.wrap(output, 1, 4).order(ByteOrder.LITTLE_ENDIAN).int
        if (length < 0 || 5 + length > output.size) return
        val reply = JSONObject(String(output, 5, length))
        val status = reply.optString("status")
        Log.i(TAG, "wallet checked: $status ${reply.optString("reason")}")
        when (status) {
            "done", "more" -> {
                // Turned off while this check ran: nothing is kept.
                if (!WatchStore.has(context, id)) return
                val state = output.copyOfRange(5 + length, output.size)
                try {
                    if (state.isNotEmpty()) WatchStore.save(context, id, state)
                } finally {
                    state.fill(0)
                }
                announce(context, id, reply)
            }
            "invalid" -> WatchStore.remove(context, id)
        }
    }

    private fun announce(context: Context, id: String, reply: JSONObject) {
        // On screen, the app shows payments itself once the wallet syncs.
        if (MainActivity.visible) return
        val payments = reply.optJSONArray("payments") ?: return
        if (payments.length() == 0) return
        val prefs = BackgroundChecks.prefs(context)
        val title = prefs.getString("$id.title", null) ?: return
        val body = prefs.getString("$id.body", null) ?: return
        val pending = prefs.getString("$id.pending", body) ?: body
        val publicTitle = prefs.getString("public", null) ?: return
        createChannels(context)
        // A handful at most, as in the app; the rest show when it opens.
        for (i in 0 until minOf(payments.length(), 3)) {
            val payment = payments.getJSONObject(i)
            val amount = payment.optString("amount")
            val template = if (payment.optBoolean("pending")) pending else body
            notifyPayment(
                context,
                (id + payment.optString("tx")).hashCode(),
                title,
                template.replace("{amount}", amount),
                publicTitle,
            )
        }
    }
}
