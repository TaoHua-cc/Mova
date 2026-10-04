package com.taohua.mova

import android.content.Context
import android.content.ComponentCallbacks2
import android.util.Log
import android.media.AudioManager
import android.content.Intent
import android.app.PictureInPictureParams
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.content.pm.PackageManager
import android.util.Rational
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Mova 的 Android 宿主。
 *
 * 除 Flutter 默认行为外额外暴露平台能力：
 *
 * 1. 屏幕亮度——播放器里「左半屏上下滑动调亮度」需要它。这里用的是**窗口级
 *    亮度**（`WindowManager.LayoutParams.screenBrightness`），而不是系统亮度，
 *    因此不需要 WRITE_SETTINGS 一类的系统权限，退出播放器 / 离开 Activity 后
 *    系统亮度会自动还原，不会污染用户的全局设置。
 * 2. 打开外部链接——设置页的 Trakt 设备授权要跳浏览器。桌面的 `cmd /c start`
 *    在安卓上不存在，只能用 `Intent.ACTION_VIEW`。
 * 3. 应用内更新——查「安装未知来源应用」的授权、跳授权页，以及把下载好的 APK
 *    交给系统安装器。Android 7.0 起不能再抛 file:// 的 URI（会
 *    FileUriExposedException），必须用 FileProvider 换成 content://。
 * 4. Exo 视频通过原生 SurfaceView 承载，并提供系统解码器与显示能力查询。
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val PLATFORM_CHANNEL = "mova/platform"
        const val SYSTEM_BRIGHTNESS_MAX = 255f
        const val SUBTITLE_REQUEST = 7302
    }

    private var pendingSubtitleResult: MethodChannel.Result? = null
    private var autoPictureInPicture = false

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S && autoPictureInPicture) {
            enterPictureInPicture()
        }
    }

    private fun configureAutoPictureInPicture(enabled: Boolean) {
        autoPictureInPicture = enabled
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            try {
                setPictureInPictureParams(PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .setAutoEnterEnabled(enabled).build())
            } catch (_: IllegalStateException) {
                autoPictureInPicture = false
            } catch (_: IllegalArgumentException) {
                autoPictureInPicture = false
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        if (packageName.endsWith(".debug")) {
            Log.i("MovaMemory", "trim=$level pid=${android.os.Process.myPid()}")
        }
        // UI_HIDDEN is a visibility notification, not an actual memory shortage.
        // Flutter's delegate maps >=10 to a VM/engine/cache purge, including 20.
        if (level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) {
            flutterEngine?.renderer?.onTrimMemory(level)
            flutterEngine?.platformViewsController?.onTrimMemory(level)
            return
        }
        super.onTrimMemory(level)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeControlStream = AudioManager.STREAM_MUSIC
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "mova/exo-video",
            ExoPlayerPlatformViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLATFORM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cleanVideoCache" -> NextEpisodeCache.clean(this, call.argument<String>("url")) {
                        runOnUiThread { result.success(null) }
                    }
                    "pickSubtitleFile" -> {
                        if (pendingSubtitleResult != null) {
                            result.error("busy", "文件选择器已打开", null)
                        } else {
                            pendingSubtitleResult = result
                            try {
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "*/*"
                                }, SUBTITLE_REQUEST)
                            } catch (_: Exception) {
                                pendingSubtitleResult = null
                                result.error("picker_unavailable", "无法打开文件选择器", null)
                            }
                        }
                    }
                    "getMediaVolume", "setMediaVolume" -> {
                        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                        if (call.method == "setMediaVolume") {
                            val fraction = (call.argument<Number>("value")?.toDouble() ?: 0.0).coerceIn(0.0, 1.0)
                            audio.setStreamVolume(AudioManager.STREAM_MUSIC,
                                kotlin.math.round(fraction * maximum).toInt(), 0)
                        }
                        result.success(audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maximum)
                    }
                    "getBrightness" -> result.success(currentBrightness())
                    "setBrightness" -> {
                        val value = (call.argument<Double>("value") ?: 0.5)
                            .coerceIn(0.0, 1.0)
                            .toFloat()
                        // 亮度取 0 会让屏幕几乎不可见，留一个下限，
                        // 保证用户滑到底也还能看清界面把亮度调回来。
                        window.attributes = window.attributes.apply {
                            screenBrightness = if (value < 0.01f) 0.01f else value
                        }
                        result.success(null)
                    }
                    "resetBrightness" -> {
                        window.attributes = window.attributes.apply {
                            screenBrightness =
                                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        }
                        result.success(null)
                    }
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    "canInstallApk" -> result.success(canInstallApk())
                    "requestInstallApk" -> result.success(requestInstallApk())
                    "installApk" -> result.success(
                        installApk(call.argument<String>("path")),
                    )
                    "networkType" -> result.success(networkType())
                    "enterPictureInPicture" -> result.success(enterPictureInPicture())
                    "setAutoPictureInPicture" -> {
                        configureAutoPictureInPicture(call.argument<Boolean>("enabled") == true)
                        result.success(null)
                    }
                    "dolbyVisionCapabilities" -> result.success(
                        DolbyVisionSupport.query(this).asMap(),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun enterPictureInPicture(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            !packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        ) return false
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        } catch (_: IllegalArgumentException) {
            false
        } catch (_: IllegalStateException) {
            false
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SUBTITLE_REQUEST) {
            val pending = pendingSubtitleResult ?: return
            pendingSubtitleResult = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            Thread {
                var target: File? = null
                try {
                    val name = contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    } ?: throw IllegalArgumentException("没有文件名")
                    val extension = name.substringAfterLast('.', "").lowercase()
                    require(extension in listOf("srt", "ass", "ssa", "vtt")) { "不支持的字幕格式" }
                    target = File.createTempFile("subtitle-", ".$extension", cacheDir)
                    contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use { output ->
                            val buffer = ByteArray(8192)
                            var total = 0
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= 20 * 1024 * 1024) { "字幕超过 20 MB" }
                                output.write(buffer, 0, count)
                            }
                            require(total > 0) { "字幕为空" }
                        }
                    } ?: throw IllegalArgumentException("无法读取字幕")
                    val path = target.absolutePath
                    runOnUiThread { pending.success(path) }
                } catch (_: Exception) {
                    target?.delete()
                    runOnUiThread { pending.error("subtitle_import", "无法读取有效字幕文件", null) }
                }
            }.start()
            return
        }
    }

    private fun networkType(): String {
        return try {
            val manager =
                getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                    ?: return "none"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val network = manager.activeNetwork ?: return "none"
                val caps =
                    manager.getNetworkCapabilities(network) ?: return "none"
                when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ->
                        "ethernet"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ->
                        "mobile"
                    else -> "other"
                }
            } else {
                val info = manager.activeNetworkInfo ?: return "none"
                when (info.type) {
                    ConnectivityManager.TYPE_WIFI -> "wifi"
                    ConnectivityManager.TYPE_ETHERNET -> "ethernet"
                    else -> if (info.subtype > 0) "mobile" else "other"
                }
            }
        } catch (_: Exception) {
            "none"
        }
    }

    /**
     * 用系统浏览器打开链接，返回是否成功发起。
     *
     * 没有可处理 ACTION_VIEW 的应用时返回 false，调用方会把授权地址原样显示
     * 出来，让用户自己复制到浏览器打开。
     */
    private fun openUrl(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        return try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 当前亮度，取值 0..1。
     *
     * 窗口亮度为 -1（BRIGHTNESS_OVERRIDE_NONE，表示跟随系统）时回读系统设定
     * 值，否则第一次滑动会从错误的基准开始跳变。
     */
    private fun currentBrightness(): Double {
        val windowBrightness = window.attributes.screenBrightness
        if (windowBrightness >= 0f) return windowBrightness.toDouble()
        return try {
            Settings.System.getInt(
                contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
            ) / SYSTEM_BRIGHTNESS_MAX.toDouble()
        } catch (_: Exception) {
            0.5
        }
    }

    /**
     * 是否已被允许「安装未知来源应用」。
     *
     * Android 8.0 起这是逐应用授权：清单里的 REQUEST_INSTALL_PACKAGES 只是
     * 申请资格，用户还得在设置里为本应用打开开关。低于 8.0 的系统没有这个
     * 开关，直接算允许。
     */
    private fun canInstallApk(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    /** 跳到本应用的「安装未知应用」授权页，返回是否成功跳转。 */
    private fun requestInstallApk(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 把下载好的 APK 交给系统安装器，返回是否成功调起。
     *
     * APK 放在应用私有缓存目录里，别的进程直接读不到，所以要经 FileProvider
     * 换一个 content:// 地址并授予读权限。安装结果（成功 / 用户取消 / 签名不符）
     * 由系统界面负责提示，这里只判断「有没有调起来」。
     */
    private fun installApk(path: String?): Boolean {
        if (path.isNullOrBlank()) return false
        val file = File(path)
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file,
            )
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
            true
        } catch (_: Exception) {
            false
        }
    }
}
