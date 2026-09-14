package com.taohua.mova

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import androidx.media3.common.C
import androidx.media3.common.AudioAttributes
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView

/**
 * Full-screen native Dolby Vision player.
 *
 * PlayerView uses a SurfaceView by default. Keeping this as a native Activity is
 * intentional: putting decoded frames in a Flutter Texture would route them
 * through an RGBA compositor and lose the platform Dolby Vision output path.
 */
class DolbyVisionPlayerActivity : Activity(), Player.Listener {
    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_CONTAINER = "container"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_HEADER_NAMES = "headerNames"
        const val EXTRA_HEADER_VALUES = "headerValues"
        const val EXTRA_RESULT_POSITION_MS = "positionMs"
        const val EXTRA_RESULT_DURATION_MS = "durationMs"
        const val EXTRA_RESULT_COMPLETED = "completed"
        const val EXTRA_RESULT_NATIVE_DV = "nativeDolbyVision"
        const val EXTRA_RESULT_ERROR = "error"
    }

    private var player: ExoPlayer? = null
    private var playerView: PlayerView? = null
    private var nativeDolbyVisionSelected = false
    private var playbackError: String? = null
    private var resultSent = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enterImmersiveMode()

        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        if (url.isBlank()) {
            finishWithResult("播放地址为空")
            return
        }

        val view = PlayerView(this).apply {
            setBackgroundColor(Color.BLACK)
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            useController = true
            controllerShowTimeoutMs = 3000
            controllerAutoShow = true
            keepScreenOn = true
        }
        playerView = view
        setContentView(view)

        val headers = readHeaders()
        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent("Mova-Android-DolbyVision")
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
        val dataSourceFactory = DefaultDataSource.Factory(this, httpFactory)
        val exoPlayer = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .build()
        player = exoPlayer
        view.player = exoPlayer
        exoPlayer.addListener(this)
        exoPlayer.setAudioAttributes(AudioAttributes.DEFAULT, true)
        val container = intent.getStringExtra(EXTRA_CONTAINER).orEmpty().lowercase()
        val mimeType = when (container) {
            "mp4", "m4v", "mov" -> MimeTypes.VIDEO_MP4
            "mkv", "matroska" -> MimeTypes.VIDEO_MATROSKA
            "ts", "m2ts", "mpegts" -> MimeTypes.VIDEO_MP2T
            else -> null
        }
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(url))
            .apply { if (mimeType != null) setMimeType(mimeType) }
            .build()
        exoPlayer.setMediaItem(mediaItem)
        val start = intent.getLongExtra(EXTRA_POSITION_MS, 0L).coerceAtLeast(0L)
        if (start > 0L) exoPlayer.seekTo(start)
        exoPlayer.prepare()
        exoPlayer.playWhenReady = true
    }

    override fun onTracksChanged(tracks: Tracks) {
        nativeDolbyVisionSelected = tracks.groups.any { group ->
            group.isSelected && (0 until group.length).any { index ->
                group.isTrackSelected(index) &&
                    group.getTrackFormat(index).sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION
            }
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        playbackError = error.errorCodeName
        Toast.makeText(this, "原生 Dolby Vision 播放失败：${error.errorCodeName}", Toast.LENGTH_LONG)
            .show()
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        if (playbackState == Player.STATE_ENDED) finishWithResult(null)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersiveMode()
    }

    @Suppress("DEPRECATION")
    private fun enterImmersiveMode() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    private fun readHeaders(): Map<String, String> {
        val names = intent.getStringArrayExtra(EXTRA_HEADER_NAMES).orEmpty()
        val values = intent.getStringArrayExtra(EXTRA_HEADER_VALUES).orEmpty()
        return names.indices
            .filter { it < values.size && names[it].isNotBlank() }
            .associate { names[it] to values[it] }
    }

    override fun finish() {
        if (!resultSent) setPlaybackResult(playbackError)
        super.finish()
    }

    private fun finishWithResult(error: String?) {
        if (resultSent) return
        setPlaybackResult(error)
        super.finish()
    }

    private fun setPlaybackResult(error: String?) {
        resultSent = true
        val current = player
        val position = current?.currentPosition?.coerceAtLeast(0L) ?: 0L
        val rawDuration = current?.duration ?: C.TIME_UNSET
        val duration = if (rawDuration == C.TIME_UNSET) 0L else rawDuration.coerceAtLeast(0L)
        val completed = duration > 0L && position.toDouble() / duration >= 0.92
        setResult(
            RESULT_OK,
            Intent().apply {
                putExtra(EXTRA_RESULT_POSITION_MS, position)
                putExtra(EXTRA_RESULT_DURATION_MS, duration)
                putExtra(EXTRA_RESULT_COMPLETED, completed)
                putExtra(EXTRA_RESULT_NATIVE_DV, nativeDolbyVisionSelected)
                if (!error.isNullOrBlank()) putExtra(EXTRA_RESULT_ERROR, error)
            },
        )
    }

    override fun onDestroy() {
        playerView?.player = null
        playerView = null
        player?.removeListener(this)
        player?.release()
        player = null
        super.onDestroy()
    }
}
