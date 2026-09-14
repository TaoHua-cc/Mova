package com.taohua.mova

import android.content.Context
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Display
import android.view.WindowManager

/** Device facts required for a genuine Android Dolby Vision output path. */
object DolbyVisionSupport {
    data class Capabilities(
        val decoder: Boolean,
        val display: Boolean,
        val decoderNames: List<String>,
    ) {
        val supported: Boolean get() = decoder && display

        fun asMap(): Map<String, Any> = mapOf(
            "supported" to supported,
            "decoder" to decoder,
            "display" to display,
            "decoderNames" to decoderNames,
        )
    }

    fun query(context: Context): Capabilities {
        val decoders = try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .asSequence()
                .filterNot { it.isEncoder }
                .filter { info ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        info.isHardwareAccelerated
                    } else {
                        val name = info.name.lowercase()
                        !name.startsWith("omx.google.") && !name.startsWith("c2.android.")
                    }
                }
                .filter { info ->
                    info.supportedTypes.any {
                        it.equals(MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION, ignoreCase = true)
                    }
                }
                .map { it.name }
                .distinct()
                .sorted()
                .toList()
        } catch (_: Exception) {
            emptyList()
        }
        return Capabilities(
            decoder = decoders.isNotEmpty(),
            display = displaySupportsDolbyVision(context),
            decoderNames = decoders,
        )
    }

    @Suppress("DEPRECATION")
    private fun displaySupportsDolbyVision(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return try {
            val manager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val display: Display = manager.defaultDisplay
            display.hdrCapabilities.supportedHdrTypes.contains(
                Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION,
            )
        } catch (_: Exception) {
            false
        }
    }
}
