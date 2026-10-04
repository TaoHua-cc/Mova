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
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.ContentMetadataMutations
import androidx.media3.database.StandaloneDatabaseProvider
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
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
    @Volatile private var released = false
    private val preloadExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var preloadWriter: CacheWriter? = null
    @Volatile private var preloadEpoch = 0
    private val nativeCache = creationParams["nativeCache"] == true
    private val originalUrl = (creationParams["cacheUrl"] as? String)
        ?: (creationParams["url"] as? String).orEmpty()
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
        NextEpisodeCache.protect(originalUrl)
        NextEpisodeCache.touch(context, originalUrl,
            (creationParams["headers"] as? Map<*, *> ?: emptyMap<Any, Any>())
                .mapNotNull { (k, v) -> if (k is String && v is String) k to v else null }.toMap())
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
        val upstream = DefaultDataSource.Factory(context, httpFactory)
        val dataSourceFactory: DataSource.Factory = if (nativeCache) try {
            CacheDataSource.Factory().setCache(NextEpisodeCache.get(context))
                .setUpstreamDataSourceFactory(upstream)
                .setCacheKeyFactory { spec -> NextEpisodeCache.key(spec.uri.toString(), headers) }
                // Playback only reads the bounded preheated prefix; no second full download.
                .setCacheWriteDataSinkFactory(null)
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        } catch (_: Exception) { upstream } else upstream
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
            "cancelPreload" -> { cancelPreload(); result.success(null) }
            "preloadNext" -> {
                val url = call.argument<String>("url").orEmpty()
                val uri = Uri.parse(url)
                if (!nativeCache || uri.scheme !in listOf("http", "https") ||
                    uri.path.orEmpty().lowercase().endsWith(".m3u8") ||
                    uri.path.orEmpty().lowercase().endsWith(".mpd")) {
                    result.success(false); return
                }
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val epoch = preloadEpoch
                preloadExecutor.execute {
                    var complete = false
                    try {
                        val factory = CacheDataSource.Factory()
                            .setCache(NextEpisodeCache.get(contextForTrace))
                            .setUpstreamDataSourceFactory(DefaultHttpDataSource.Factory()
                                .setUserAgent("Mova-Android-ExoPlayer")
                                .setAllowCrossProtocolRedirects(true)
                                .setConnectTimeoutMs(10000).setReadTimeoutMs(10000)
                                .setDefaultRequestProperties(headers))
                        val writer = CacheWriter(factory.createDataSource(), DataSpec.Builder()
                            .setUri(uri).setKey(NextEpisodeCache.key(url, headers))
                            .setLength(32L * 1024 * 1024).build(), null, null)
                        preloadWriter = writer
                        NextEpisodeCache.protect(url)
                        try {
                            if (!released && epoch == preloadEpoch) { writer.cache(); complete = true }
                        } finally {
                            NextEpisodeCache.touch(contextForTrace, url, headers)
                            NextEpisodeCache.release(contextForTrace, url)
                        }
                    } catch (_: Exception) {
                        // Optional warm-up failure must not interrupt the current episode.
                    } finally {
                        preloadWriter = null
                        mainHandler.post { result.success(complete) }
                    }
                }
            }
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

    private fun cancelPreload() { preloadEpoch++; preloadWriter?.cancel() }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        if (!isPlaying) cancelPreload()
        emitState()
    }
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
        cancelPreload()
        preloadExecutor.shutdownNow()
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
        NextEpisodeCache.release(contextForTrace, originalUrl)
    }
}

/** Separate native cache; never changes or deletes legacy Dart cache files. */
internal object NextEpisodeCache {
    private var cache: SimpleCache? = null
    private val maintenance = Executors.newSingleThreadExecutor()
    private val active = mutableMapOf<String, Int>()
    private val pending = mutableSetOf<String>()
    @Synchronized fun protect(url: String) {
        val id = key(url, emptyMap())
        active[id] = (active[id] ?: 0) + 1
    }
    fun release(context: Context, url: String) {
        synchronized(this) {
            val id = key(url, emptyMap())
            val count = (active[id] ?: 1) - 1
            if (count <= 0) active.remove(id) else active[id] = count
        }
        clean(context)
    }
    fun touch(context: Context, url: String, headers: Map<String, String>) {
        maintenance.execute {
            try {
                get(context).applyContentMetadataMutations(key(url, headers), ContentMetadataMutations()
                    .set("mova.url", key(url, emptyMap()))
                    .set("mova.lastUsed", System.currentTimeMillis()))
            } catch (_: Exception) {}
        }
    }
    fun clean(context: Context, url: String? = null, finished: (() -> Unit)? = null) {
        maintenance.execute {
            try {
                val store = get(context)
                synchronized(this) {
                    if (url != null) pending.add(key(url, emptyMap()))
                    val cutoff = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
                    for (item in store.keys.toList()) {
                        val meta = store.getContentMetadata(item)
                        val id = meta.get("mova.url", "")
                        if ((active[id] ?: 0) > 0) continue
                        val touched = maxOf(meta.get("mova.lastUsed", 0L),
                            store.getCachedSpans(item).maxOfOrNull { it.lastTouchTimestamp } ?: 0L)
                        if (id in pending || touched <= cutoff) store.removeResource(item)
                    }
                    pending.removeAll { (active[it] ?: 0) == 0 }
                }
            } catch (_: Exception) {
                // Failed maintenance can be retried on next launch/release.
            } finally { finished?.invoke() }
        }
    }
    @Synchronized fun get(context: Context): SimpleCache = cache ?: SimpleCache(
        File(context.applicationContext.cacheDir, "exo-next-prefix"),
        LeastRecentlyUsedCacheEvictor(128L * 1024 * 1024),
        StandaloneDatabaseProvider(context.applicationContext),
    ).also { cache = it }

    fun key(url: String, headers: Map<String, String>): String = MessageDigest.getInstance("SHA-256")
        .digest((url + "\n" + headers.toSortedMap().entries.joinToString("\n") {
            "${it.key}:${it.value}"
        }).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
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
