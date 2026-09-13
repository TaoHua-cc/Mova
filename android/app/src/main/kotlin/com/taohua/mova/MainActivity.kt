package com.taohua.mova

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Mova 的 Android 宿主。
 *
 * 除 Flutter 默认行为外额外暴露三项能力：
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
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val PLATFORM_CHANNEL = "mova/platform"
        const val SYSTEM_BRIGHTNESS_MAX = 255f
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLATFORM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                    else -> result.notImplemented()
                }
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
