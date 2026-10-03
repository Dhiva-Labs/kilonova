package com.dhivalabs.kilonova

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Copies a file the app wrote to its cache (a backup) to where the user
// picks, through the system's document picker. The app needs no storage
// permission and never sees other files. Must be created while the
// activity is being constructed, because it registers for a result.
class SaveDocument(private val activity: FragmentActivity) : MethodChannel.MethodCallHandler {
    private var pending: Pair<File, MethodChannel.Result>? = null

    private val launcher =
        activity.registerForActivityResult(
            ActivityResultContracts.CreateDocument("application/octet-stream"),
        ) { uri -> finish(uri) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveDocument" -> {
                val path = call.argument<String>("path")
                val name = call.argument<String>("name")
                if (path == null || name == null || pending != null) {
                    result.error("bad_request", "a save is already open", null)
                    return
                }
                pending = File(path) to result
                launcher.launch(name)
            }
            else -> result.notImplemented()
        }
    }

    private fun finish(uri: Uri?) {
        val (file, result) = pending ?: return
        pending = null
        if (uri == null) {
            result.success(null)
            return
        }
        try {
            val out = activity.contentResolver.openOutputStream(uri, "wt")
                ?: throw IllegalStateException("cannot write there")
            out.use { stream -> file.inputStream().use { it.copyTo(stream) } }
            result.success(displayName(uri) ?: file.name)
        } catch (e: Exception) {
            result.error("save_failed", e.message, null)
        }
    }

    private fun displayName(uri: Uri): String? =
        activity.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
}
