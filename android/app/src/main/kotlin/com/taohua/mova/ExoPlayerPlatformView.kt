package com.taohua.mova

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.os.Build
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicLong
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Native Exo video surface hosted by Flutter; all transport UI stays in Flutter. */
class ExoPlayerPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    creationParams: Map<String, Any?>,
) : PlatformView, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    Player.Listener {

    private val playerView = PlayerView(context).apply {
        useController = false
        controllerAutoShow = false
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        setBackgroundColor(android.graphics.Color.BLACK)
        setShutterBackgroundColor(android.graphics.Color.BLACK)
        setKeepContentOnPlayerReset(false)
        keepScreenOn = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val methodChannel = MethodChannel(messenger, "mova/exo/$viewId")
    private val eventChannel = EventChannel(messenger, "mova/exo-events/$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var released = false
    private val exoPlayer: ExoPlayer
    private val transferTrace = creationParams["transferTrace"] == true
    private var lastBufferTraceMs = 0L
    private val readBytes = AtomicLong(0L)
    private var speedSampleMs = SystemClock.elapsedRealtime()
    private var readBytesPerSecond = 0.0
    private var tracksPending = true
    private var pendingExternalSubtitle = false
    private var menuVisible = false
    private val menuSurfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) { applyMenuFrameRate() }
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            applyMenuFrameRate()
        }
        override fun surfaceDestroyed(holder: SurfaceHolder) {}
    }

    private fun applyMenuFrameRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val surface = (playerView.videoSurfaceView as? SurfaceView)?.holder?.surface ?: return
        if (!surface.isValid) return
        val display = playerView.display ?: return
        val rate = if (menuVisible) {
            display.supportedModes.filter {
                it.physicalWidth == display.mode.physicalWidth &&
                    it.physicalHeight == display.mode.physicalHeight && it.refreshRate <= 120.1f
            }.maxOfOrNull { it.refreshRate } ?: display.refreshRate
        } else 0f
        try {
            surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            if (contextForTrace.packageName.endsWith(".debug")) {
                Log.i("MovaExoMenuRate", "visible=$menuVisible requested=$rate actual=${display.refreshRate}")
            }
        } catch (_: IllegalArgumentException) {
            // A display/surface change can invalidate a formerly supported hint.
        } catch (_: IllegalStateException) {
            // Surface teardown must not interrupt playback or exit.
        }
    }
    private val contextForTrace = context

    private val ticker = object : Runnable {
        override fun run() {
            if (released) return
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - speedSampleMs
            if (elapsed >= 1000L) {
                readBytesPerSecond = readBytes.getAndSet(0L) * 1000.0 / elapsed
                speedSampleMs = now
            }
            emitState()
            if (transferTrace && SystemClock.elapsedRealtime() - lastBufferTraceMs >= 5000L) {
                lastBufferTraceMs = SystemClock.elapsedRealtime()
                tracePlayback("directProbe")
            }
            mainHandler.postDelayed(this, 250L)
        }
    }

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)

        val headers = (creationParams["headers"] as? Map<*, *> ?: emptyMap<Any, Any>())
            .mapNotNull { (key, value) ->
                val name = key as? String ?: return@mapNotNull null
                val headerValue = value as? String ?: return@mapNotNull null
                name to headerValue
            }.toMap()
        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent("Mova-Android-ExoPlayer")
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
            httpFactory.setTransferListener(object : TransferListener {
                private var startedMs = 0L
                private var reportedMs = 0L
                private var bytes = 0L
                override fun onTransferInitializing(source: DataSource, spec: DataSpec, network: Boolean) {}
                override fun onTransferStart(source: DataSource, spec: DataSpec, network: Boolean) {
                    startedMs = SystemClock.elapsedRealtime()
                    reportedMs = startedMs
                    bytes = 0
                    if (transferTrace) Log.i("MovaExoTransfer", "event=start")
                }
                override fun onBytesTransferred(source: DataSource, spec: DataSpec, network: Boolean, count: Int) {
                    bytes += count
                    if (network) readBytes.addAndGet(count.toLong())
                    val now = SystemClock.elapsedRealtime()
                    if (transferTrace && now - reportedMs >= 5000L) {
                        reportedMs = now
                        Log.i("MovaExoTransfer", "elapsedMs=${now - startedMs} bytes=$bytes")
                    }
                }
                override fun onTransferEnd(source: DataSource, spec: DataSpec, network: Boolean) {
                    if (transferTrace) Log.i("MovaExoTransfer", "event=end elapsedMs=${SystemClock.elapsedRealtime() - startedMs} bytes=$bytes")
                }
            })
        val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
        val renderersFactory = DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
        exoPlayer = ExoPlayer.Builder(context, renderersFactory)
            // Video cadence must not lower the refresh rate of Flutter menus.
            // This changes display hints, not the decoded frame rate or quality.
            .setVideoChangeFrameRateStrategy(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .build()
        exoPlayer.addListener(this)
        exoPlayer.setAudioAttributes(AudioAttributes.DEFAULT, true)
        playerView.player = exoPlayer
        (playerView.videoSurfaceView as? SurfaceView)?.holder?.addCallback(menuSurfaceCallback)

        val container = (creationParams["container"] as? String).orEmpty().lowercase()
        val mime = when (container) {
            "mp4", "m4v", "mov" -> "video/mp4"
            "mkv", "matroska" -> "video/x-matroska"
            "ts", "m2ts", "mpegts" -> "video/mp2t"
            else -> null
        }
        val item = MediaItem.Builder()
            .setUri(Uri.parse(creationParams["url"] as? String ?: ""))
            .apply { if (mime != null) setMimeType(mime) }
            .build()
        exoPlayer.setMediaItem(item)
        val position = (creationParams["positionMs"] as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L
        if (position > 0) exoPlayer.seekTo(position)
        exoPlayer.prepare()
        exoPlayer.playWhenReady = true
        mainHandler.post(ticker)
    }

    override fun getView(): View = playerView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setMenuVisible" -> {
                menuVisible = call.argument<Boolean>("visible") == true
                applyMenuFrameRate()
                result.success(null)
            }
            "play" -> { exoPlayer.play(); result.success(null) }
            "pause" -> { exoPlayer.pause(); result.success(null) }
            "toggle" -> { exoPlayer.playWhenReady = !exoPlayer.playWhenReady; result.success(null) }
            "seekTo" -> {
                exoPlayer.seekTo((call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L))
                result.success(null)
            }
            "setVolume" -> {
                exoPlayer.volume = (call.argument<Number>("volume")?.toFloat() ?: 1f).coerceIn(0f, 1f)
                result.success(null)
            }
            "setRate" -> {
                exoPlayer.setPlaybackSpeed((call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(0.25f, 4f))
                result.success(null)
            }
            "setTrack" -> selectTrack(call, result)
            "addSubtitle" -> {
                val path = call.argument<String>("path") ?: ""
                val extension = path.substringAfterLast('.', "").lowercase()
                val mime = when (extension) {
                    "srt" -> androidx.media3.common.MimeTypes.APPLICATION_SUBRIP
                    "ass", "ssa" -> androidx.media3.common.MimeTypes.TEXT_SSA
                    "vtt" -> androidx.media3.common.MimeTypes.TEXT_VTT
                    else -> { result.error("invalid_subtitle", "不支持的字幕格式", null); return }
                }
                val item = exoPlayer.currentMediaItem
                if (item == null || !java.io.File(path).isFile) {
                    result.error("invalid_subtitle", "字幕文件不可用", null); return
                }
                val subtitle = MediaItem.SubtitleConfiguration.Builder(Uri.fromFile(java.io.File(path)))
                    .setId("mova-external")
                    .setMimeType(mime).setLabel(call.argument<String>("label") ?: "本地字幕")
                    .setSelectionFlags(C.SELECTION_FLAG_DEFAULT).build()
                val position = exoPlayer.currentPosition
                val playing = exoPlayer.playWhenReady
                exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters.buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    .clearOverridesOfType(C.TRACK_TYPE_TEXT).build()
                pendingExternalSubtitle = true
                exoPlayer.setMediaItem(item.buildUpon().setSubtitleConfigurations(listOf(subtitle)).build(), position)
                exoPlayer.prepare()
                exoPlayer.playWhenReady = playing
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun selectTrack(call: MethodCall, result: MethodChannel.Result) {
        val type = when (call.argument<String>("type")) {
            "audio" -> C.TRACK_TYPE_AUDIO
            "text" -> C.TRACK_TYPE_TEXT
            else -> { result.error("invalid_track", "音轨类型无效", null); return }
        }
        val flatIndex = call.argument<Number>("index")?.toInt() ?: -1
        val tracks = exoPlayer.currentTracks.groups
            .filter { it.type == type }
            .flatMap { group -> (0 until group.length).map { Triple(group, it, group.getTrackFormat(it)) } }
        if (flatIndex < 0) {
            exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters
                .buildUpon().clearOverridesOfType(type)
                .setTrackTypeDisabled(type, call.argument<String>("selection") != "auto").build()
            result.success(null)
            return
        }
        val selected = tracks.getOrNull(flatIndex)
        if (selected == null) {
            result.error("track_not_found", "找不到所选音轨", null)
            return
        }
        exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(selected.first.mediaTrackGroup, selected.second))
            .build()
        result.success(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        tracksPending = true
        emitState()
    }

    override fun onCancel(arguments: Any?) { eventSink = null }

    override fun onIsPlayingChanged(isPlaying: Boolean) = emitState()
    override fun onPlaybackStateChanged(playbackState: Int) {
        tracePlayback("state=$playbackState")
        emitState()
    }
    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
        tracePlayback("requestReason=$reason")
        emitState()
    }
    override fun onPlaybackSuppressionReasonChanged(playbackSuppressionReason: Int) {
        tracePlayback("suppression=$playbackSuppressionReason")
        emitState()
    }

    private fun tracePlayback(change: String) {
        // State only: never include URLs, headers, tokens or media titles.
        Log.i("MovaExo", "$change requested=${exoPlayer.playWhenReady} " +
            "rendering=${exoPlayer.isPlaying} state=${exoPlayer.playbackState} " +
            "positionMs=${exoPlayer.currentPosition} " +
            "bufferAheadMs=${(exoPlayer.bufferedPosition - exoPlayer.currentPosition).coerceAtLeast(0L)}")
    }
    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
        eventSink?.success(mapOf("error" to error.errorCodeName))
    }
    override fun onTracksChanged(tracks: Tracks) {
        if (pendingExternalSubtitle) {
            for (group in tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }) {
                val index = (0 until group.length).firstOrNull { group.getTrackFormat(it).id == "mova-external" }
                if (index != null && group.isTrackSupported(index)) {
                    pendingExternalSubtitle = false
                    exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, index)).build()
                    break
                }
            }
        }
        tracksPending = true
        emitState()
    }

    private fun emitState() {
        if (released) return
        val rawDuration = exoPlayer.duration
        val duration = if (rawDuration == C.TIME_UNSET) 0L else rawDuration.coerceAtLeast(0L)
        val sink = eventSink ?: return
        val state = mutableMapOf<String, Any?>(
            "positionMs" to exoPlayer.currentPosition.coerceAtLeast(0L),
            "durationMs" to duration,
            "bufferedMs" to exoPlayer.bufferedPosition.coerceAtLeast(0L),
            "readBytesPerSecond" to readBytesPerSecond,
            // isPlaying is false while buffering even when no pause was requested.
            "playing" to (exoPlayer.playWhenReady &&
                exoPlayer.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE &&
                exoPlayer.playbackState != Player.STATE_ENDED),
            "rendering" to exoPlayer.isPlaying,
            "buffering" to (exoPlayer.playbackState == Player.STATE_BUFFERING),
            "completed" to (exoPlayer.playbackState == Player.STATE_ENDED),
        )
        // Track lists change independently of the 250 ms position ticker.
        // Resend on subscription so a newly attached Flutter listener is complete.
        if (tracksPending) {
            state["tracks"] = flattenTracks(exoPlayer.currentTracks)
            tracksPending = false
        }
        sink.success(state)
    }

    private fun flattenTracks(tracks: Tracks): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        for (group in tracks.groups) {
            if (group.type != C.TRACK_TYPE_AUDIO && group.type != C.TRACK_TYPE_TEXT) continue
            for (index in 0 until group.length) {
                val format: Format = group.getTrackFormat(index)
                result += mapOf(
                    "type" to if (group.type == C.TRACK_TYPE_AUDIO) "audio" else "text",
                    "index" to result.count { it["type"] == if (group.type == C.TRACK_TYPE_AUDIO) "audio" else "text" },
                    "label" to (format.label ?: format.language ?: format.sampleMimeType ?: "音轨"),
                    "language" to format.language,
                    "selected" to group.isTrackSelected(index),
                    "supported" to group.isTrackSupported(index),
                )
            }
        }
        return result
    }

    override fun dispose() {
        if (released) return
        released = true
        menuVisible = false
        applyMenuFrameRate()
        (playerView.videoSurfaceView as? SurfaceView)?.holder?.removeCallback(menuSurfaceCallback)
        mainHandler.removeCallbacks(ticker)
        eventSink = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        playerView.player = null
        exoPlayer.removeListener(this)
        exoPlayer.release()
    }
}

class ExoPlayerPlatformViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        return ExoPlayerPlatformView(context, messenger, viewId, params)
    }
}
