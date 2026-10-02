package com.dhivalabs.kilonova

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity, because BiometricPrompt needs one.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Screens that show a seed set FLAG_SECURE, which blocks screenshots,
        // screen recording and the recent-apps thumbnail.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kilonova/secure_window")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kilonova/biometric")
            .setMethodCallHandler(BiometricVault(this))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kilonova/background")
            .setMethodCallHandler(BackgroundSync(this))
    }
}
