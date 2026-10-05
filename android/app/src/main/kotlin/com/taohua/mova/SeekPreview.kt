package com.taohua.mova

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors

/** One independent extraction at a time; never seek the playback engine. */
object SeekPreview {
    // ponytail: framework network extraction can outlive the UI's 8s deadline;
    // keep one worker globally, use a cancellable extractor if real-device stalls recur.
    private val busy = AtomicBoolean(false)
    private val worker = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    // All session fields are confined to worker; only one low-resolution decoder.
    private var reader: MediaMetadataRetriever? = null
    private var sourceUrl: String? = null
    private var sourceHeaders = emptyMap<String, String>()
    private val frames = linkedMapOf<Long, ByteArray>()
    private var cacheBytes = 0
    private var lastUse = 0L
    private val idleClose = Runnable {
        worker.execute { if (SystemClock.elapsedRealtime() - lastUse >= 30000) release() }
    }

    private fun release() {
        try { reader?.release() } catch (_: Exception) {}
        reader = null
        sourceUrl = null
        sourceHeaders = emptyMap()
        frames.clear()
        cacheBytes = 0
    }

    fun close() {
        handler.removeCallbacks(idleClose)
        worker.execute { release() }
    }

    fun frame(url: String, headers: Map<String, String>, milliseconds: Long, done: (ByteArray?) -> Unit) {
        if (!busy.compareAndSet(false, true)) { Log.i("MovaSeekPreview", "busy"); done(null); return }
        worker.execute {
            val started = SystemClock.elapsedRealtime()
            var frame: Bitmap? = null
            var scaled: Bitmap? = null
            var bytes: ByteArray? = null
            try {
                handler.removeCallbacks(idleClose)
                if (reader == null || sourceUrl != url || sourceHeaders != headers) {
                    release()
                    val opened = MediaMetadataRetriever()
                    reader = opened
                    Log.i("MovaSeekPreview", "source begin")
                    if (url.startsWith("http://") || url.startsWith("https://")) opened.setDataSource(url, headers)
                    else opened.setDataSource(url)
                    sourceUrl = url
                    sourceHeaders = headers.toMap()
                    Log.i("MovaSeekPreview", "source ready ms=${SystemClock.elapsedRealtime() - started}")
                } else Log.i("MovaSeekPreview", "source reused")
                bytes = frames[milliseconds]
                if (bytes != null) {
                    Log.i("MovaSeekPreview", "cache hit ms=${SystemClock.elapsedRealtime() - started}")
                } else {
                val activeReader = reader!!
                frame = if (Build.VERSION.SDK_INT >= 27) {
                    activeReader.getScaledFrameAtTime(milliseconds.coerceAtLeast(0) * 1000,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 320, 180)
                } else {
                    activeReader.getFrameAtTime(milliseconds.coerceAtLeast(0) * 1000,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                }
                frame?.let {
                    val width = minOf(320, it.width)
                    val height = maxOf(1, it.height * width / it.width)
                    scaled = Bitmap.createScaledBitmap(it, width, height, true)
                    val output = ByteArrayOutputStream()
                    scaled!!.compress(Bitmap.CompressFormat.JPEG, 80, output)
                    bytes = output.toByteArray()
                    if (bytes!!.size <= 1024 * 1024) {
                        while (frames.isNotEmpty() && (frames.size >= 12 || cacheBytes + bytes!!.size > 1024 * 1024)) {
                            cacheBytes -= frames.remove(frames.keys.first())!!.size
                        }
                        frames[milliseconds] = bytes!!
                        cacheBytes += bytes!!.size
                    }
                }
                }
                Log.i("MovaSeekPreview", "frame bytes=${bytes?.size ?: 0} ms=${SystemClock.elapsedRealtime() - started}")
            } catch (error: Exception) {
                Log.i("MovaSeekPreview", "failure=${error.javaClass.simpleName} ms=${SystemClock.elapsedRealtime() - started}")
                release()
                // Unsupported media/network failures leave the time-only preview.
            } finally {
                if (scaled !== frame) scaled?.recycle()
                frame?.recycle()
                lastUse = SystemClock.elapsedRealtime()
                handler.postDelayed(idleClose, 30000)
                busy.set(false)
                done(bytes)
            }
        }
    }
}
