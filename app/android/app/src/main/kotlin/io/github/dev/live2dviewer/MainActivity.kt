package io.github.dev.live2dviewer

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.view.Surface
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class MainActivity : FlutterActivity() {
    private val immersiveChannelName = "live2d_viewer/immersive"
    private val textureChannelName = "live2d_viewer/texture_android"
    private val storagePermChannelName = "live2d_viewer/storage_permission"

    private var surfaceEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var nativeWindowPtr: Long = 0

    external fun getNativeWindowPtr(surface: Surface): Long
    external fun releaseNativeWindow(ptr: Long)

    companion object {
        init {
            System.loadLibrary("native_window")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, immersiveChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> { hideSystemBars(); result.success(null) }
                    "disable" -> { showSystemBars(); result.success(null) }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, textureChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "create" -> {
                        val width = call.argument<Int>("width") ?: 512
                        val height = call.argument<Int>("height") ?: 512
                        destroySurface()

                        val entry = flutterEngine.renderer.createSurfaceTexture()
                        entry.surfaceTexture().setDefaultBufferSize(width, height)
                        val s = Surface(entry.surfaceTexture())
                        val nativeWindow = getNativeWindowPtr(s)

                        surfaceEntry = entry
                        surface = s
                        nativeWindowPtr = nativeWindow

                        result.success(mapOf(
                            "texture_id" to entry.id(),
                            "native_window" to nativeWindow
                        ))
                    }
                    "resize" -> {
                        val width = call.argument<Int>("width") ?: return@setMethodCallHandler
                        val height = call.argument<Int>("height") ?: return@setMethodCallHandler
                        surfaceEntry?.surfaceTexture()?.setDefaultBufferSize(width, height)
                        result.success(null)
                    }
                    "destroy" -> {
                        destroySurface()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storagePermChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    "hasAllFilesAccess" -> {
                        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            Environment.isExternalStorageManager()
                        } else {
                            true
                        }
                        result.success(granted)
                    }
                    "openAllFilesAccessSettings" -> {
                        // Try intents in order of specificity. Some OEM ROMs
                        // (e.g. Huawei EMUI/HarmonyOS) don't implement the
                        // per-app or global "All files access" intents at all
                        // — `startActivity` throws `ActivityNotFoundException`
                        // and the button appears to do nothing. The reliable
                        // fallback on every Android ROM is the app details
                        // page, where the user taps "Permissions" → "All files
                        // access" themselves.
                        val intents = mutableListOf<Intent>()
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            intents.add(
                                Intent(
                                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            intents.add(
                                Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            )
                        }
                        intents.add(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")
                            )
                        )
                        var opened = false
                        for (intent in intents) {
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try {
                                startActivity(intent)
                                opened = true
                                break
                            } catch (e: Exception) {
                                // This ROM doesn't implement this intent — try next.
                            }
                        }
                        result.success(opened)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun destroySurface() {
        if (nativeWindowPtr != 0L) {
            releaseNativeWindow(nativeWindowPtr)
            nativeWindowPtr = 0
        }
        surface?.release()
        surface = null
        surfaceEntry?.release()
        surfaceEntry = null
    }

    private fun hideSystemBars() {
        WindowInsetsControllerCompat(window, window.decorView).let { c ->
            c.hide(WindowInsetsCompat.Type.systemBars())
            c.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun showSystemBars() {
        WindowInsetsControllerCompat(window, window.decorView)
            .show(WindowInsetsCompat.Type.systemBars())
    }
}
