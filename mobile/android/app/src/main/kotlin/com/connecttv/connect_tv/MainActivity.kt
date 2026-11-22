package com.connecttv.connect_tv

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Receives links from Android's Share menu ("Share → Connect TV") and hands them to Flutter,
// and opens the phone's own screen casting for "Mirror this phone".
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pending = sharedText(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "connecttv/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeShared") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "connecttv/cast").setMethodCallHandler { call, result ->
            if (call.method == "castScreen") result.success(openCast()) else result.notImplemented()
        }
    }

    // The TV has Chromecast built in. Try the phone's Cast screen settings first, then the
    // Google Home app ("Cast my screen"), then Google Home in the Play Store.
    // Returns which one opened ("settings", "home", "store") or null.
    private fun openCast(): String? {
        // Samsung's Cast settings open its own Smart View screen mirroring, which may not list a Chromecast
        // TV, so Samsung phones go to Google Home first.
        val samsung = Build.MANUFACTURER.equals("samsung", ignoreCase = true)
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(GOOGLE_HOME)
        if (samsung && tryStart(home)) return "home"
        if (tryStart(Intent("android.settings.CAST_SETTINGS"))) return "settings"
        if (tryStart(home)) return "home"
        if (tryStart(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$GOOGLE_HOME")))) return "store"
        if (tryStart(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$GOOGLE_HOME")))) return "store"
        return null
    }

    private fun tryStart(i: Intent): Boolean = try {
        startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }

    companion object {
        private const val GOOGLE_HOME = "com.google.android.apps.chromecast.app"
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val text = sharedText(intent) ?: return
        pending = text
        channel?.invokeMethod("shared", null)
    }

    private fun sharedText(i: Intent?): String? =
        if (i?.action == Intent.ACTION_SEND && i.type?.startsWith("text/") == true) i.getStringExtra(Intent.EXTRA_TEXT) else null
}
