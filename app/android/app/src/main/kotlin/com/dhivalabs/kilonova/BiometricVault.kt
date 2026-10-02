package com.dhivalabs.kilonova

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keeps each wallet's password encrypted under its own Android Keystore key.
 *
 * The key never leaves the secure hardware and can only be used for one
 * operation after a strong biometric check (the cipher is passed to
 * BiometricPrompt as a CryptoObject, so a bare "success" callback is not
 * enough). Enrolling a new fingerprint or face invalidates the key, and the
 * wallet falls back to its password.
 */
class BiometricVault(private val activity: FragmentActivity) : MethodChannel.MethodCallHandler {
    private val prefs = activity.getSharedPreferences("kilonova_biometric", Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "isEnabled" -> result.success(id != null && prefs.contains(id))
            "enable" -> enable(
                id!!,
                call.argument<String>("password")!!,
                call.argument<String>("title")!!,
                call.argument<String>("cancel")!!,
                result,
            )
            "unlock" -> unlock(
                id!!,
                call.argument<String>("title")!!,
                call.argument<String>("cancel")!!,
                result,
            )
            "disable" -> {
                disable(id!!)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun isAvailable() =
        BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS

    private fun enable(
        id: String,
        password: String,
        title: String,
        cancel: String,
        result: MethodChannel.Result,
    ) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, createKey(id))
        prompt(cipher, title, cancel, result) { authed ->
            val sealed = authed.doFinal(password.toByteArray(Charsets.UTF_8))
            prefs.edit()
                .putString(id, encode(authed.iv) + ":" + encode(sealed))
                .apply()
            result.success(true)
        }
    }

    private fun unlock(id: String, title: String, cancel: String, result: MethodChannel.Result) {
        val stored = prefs.getString(id, null)
        val key = keyStore().getKey(alias(id), null) as SecretKey?
        if (stored == null || key == null) {
            disable(id)
            result.error("not_enabled", null, null)
            return
        }
        val (iv, sealed) = stored.split(":").map { Base64.decode(it, Base64.NO_WRAP) }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        try {
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        } catch (e: KeyPermanentlyInvalidatedException) {
            disable(id)
            result.error("invalidated", null, null)
            return
        }
        prompt(cipher, title, cancel, result) { authed ->
            result.success(String(authed.doFinal(sealed), Charsets.UTF_8))
        }
    }

    private fun disable(id: String) {
        prefs.edit().remove(id).apply()
        keyStore().deleteEntry(alias(id))
    }

    private fun prompt(
        cipher: Cipher,
        title: String,
        cancel: String,
        result: MethodChannel.Result,
        onAuthenticated: (Cipher) -> Unit,
    ) {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setNegativeButtonText(cancel)
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                val authed = auth.cryptoObject?.cipher
                if (authed == null) {
                    result.error("failed", null, null)
                    return
                }
                try {
                    onAuthenticated(authed)
                } catch (e: Exception) {
                    result.error("failed", null, null)
                }
            }

            override fun onAuthenticationError(code: Int, message: CharSequence) {
                // Cancelling is not an error the user needs explained.
                val cancelled = code == BiometricPrompt.ERROR_USER_CANCELED ||
                    code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                    code == BiometricPrompt.ERROR_CANCELED
                result.error(if (cancelled) "cancelled" else "failed", null, null)
            }
        }
        BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    private fun createKey(id: String): SecretKey {
        val spec = KeyGenParameterSpec.Builder(
            alias(id),
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    // Every use needs a fresh biometric check.
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                }
            }
            .build()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(spec)
        return generator.generateKey()
    }

    private fun keyStore() = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun alias(id: String) = "kilonova_wallet_$id"

    private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
