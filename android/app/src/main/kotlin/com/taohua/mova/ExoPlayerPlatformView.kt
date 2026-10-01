package com.taohua.mova

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
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
        keepScreenOn = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val methodChannel = MethodChannel(messenger, "mova/exo/$viewId")
    private val eventChannel = EventChannel(messenger, "mova/exo-events/$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var released = false
    private val exoPlayer: ExoPlayer

    private val ticker = object : Runnable {
        override fun run() {
            if (released) return
            emitState()
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
        val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
        val renderersFactory = DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
        exoPlayer = ExoPlayer.Builder(context, renderersFactory)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .build()
        exoPlayer.addListener(this)
        exoPlayer.setAudioAttributes(AudioAttributes.DEFAULT, true)
        playerView.player = exoPlayer

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
            "play" -> { exoPlayer.play(); result.success(null) }
            "pause" -> { exoPlayer.pause(); result.success(null) }
            "toggle" -> { exoPlayer.playWhenReady = !exoPlayer.isPlaying; result.success(null) }
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
                .buildUpon().setTrackTypeDisabled(type, true).build()
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
        emitState()
    }

    override fun onCancel(arguments: Any?) { eventSink = null }

    override fun onIsPlayingChanged(isPlaying: Boolean) = emitState()
    override fun onPlaybackStateChanged(playbackState: Int) = emitState()
    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
        eventSink?.success(mapOf("error" to error.errorCodeName))
    }
    override fun onTracksChanged(tracks: Tracks) = emitState()

    private fun emitState() {
        if (released) return
        val rawDuration = exoPlayer.duration
        val duration = if (rawDuration == C.TIME_UNSET) 0L else rawDuration.coerceAtLeast(0L)
        eventSink?.success(mapOf(
            "positionMs" to exoPlayer.currentPosition.coerceAtLeast(0L),
            "durationMs" to duration,
            "bufferedMs" to exoPlayer.bufferedPosition.coerceAtLeast(0L),
            "playing" to exoPlayer.isPlaying,
            "buffering" to (exoPlayer.playbackState == Player.STATE_BUFFERING),
            "completed" to (exoPlayer.playbackState == Player.STATE_ENDED),
            "tracks" to flattenTracks(exoPlayer.currentTracks),
        ))
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
