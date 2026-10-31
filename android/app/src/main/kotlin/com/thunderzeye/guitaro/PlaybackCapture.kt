package com.thunderzeye.guitaro

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// Dart's `PlaybackListener`: asks the user for playback capture, runs it in
/// [PlaybackCaptureService], and streams the PCM it hears to Flutter.
class PlaybackCapture(private val activity: Activity) : CaptureSession.Listener {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var pendingStart: MethodChannel.Result? = null
    // Between startForegroundService() and the service reporting back. Stopping it in that window
    // (before it has called startForeground()) crashes the app, so a stop then waits.
    private var serviceStarting = false
    private var stopWhenStarted = false
    private val main = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        methods = MethodChannel(messenger, "guitaro/playback_capture").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    "start" -> start(result)
                    "stop" -> {
                        stopService()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        events = EventChannel(messenger, "guitaro/playback_capture/pcm").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                    sink = eventSink
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })
        }
        CaptureSession.listener = this
    }

    fun detach() {
        if (CaptureSession.listener === this) CaptureSession.listener = null
        stopService()
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        sink = null
    }

    private fun start(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "Playback capture needs Android 10 or newer.", null)
            return
        }
        if (pendingStart != null || CaptureSession.running) {
            result.error("busy", "Already capturing.", null)
            return
        }
        pendingStart = result
        val manager = activity.getSystemService(MediaProjectionManager::class.java)
        // Capture the whole display's sound (which is only ours anyway) rather than offering
        // the single-app picker, which would confuse here.
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        activity.startActivityForResult(intent, REQUEST_CODE)
    }

    /// True when this was the capture consent result.
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingStart ?: return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingStart = null
            result.error("denied", "Capture wasn't allowed.", null)
            return true
        }
        val intent = Intent(activity, PlaybackCaptureService::class.java)
            .putExtra(PlaybackCaptureService.EXTRA_RESULT_CODE, resultCode)
            .putExtra(PlaybackCaptureService.EXTRA_RESULT_DATA, data)
        try {
            activity.startForegroundService(intent)
            serviceStarting = true
        } catch (e: Exception) {
            pendingStart = null
            result.error("error", e.message ?: "Couldn't start the capture.", null)
        }
        return true
    }

    private fun stopService() {
        if (serviceStarting) {
            stopWhenStarted = true
            return
        }
        activity.stopService(Intent(activity, PlaybackCaptureService::class.java))
    }

    private fun serviceReported() {
        serviceStarting = false
        if (stopWhenStarted) {
            stopWhenStarted = false
            stopService()
        }
    }

    override fun onStarted() {
        main.post {
            pendingStart?.success(null)
            pendingStart = null
            serviceReported()
        }
    }

    override fun onPcm(bytes: ByteArray) {
        main.post { sink?.success(bytes) }
    }

    override fun onEnded(error: String?) {
        main.post {
            val start = pendingStart
            pendingStart = null
            if (error != null) {
                if (start != null) start.error("error", error, null) else sink?.error("error", error, null)
            } else {
                start?.error("error", "Capture stopped before it began.", null)
                sink?.endOfStream()
            }
            serviceReported()
            // However it ended, take the service (and its notification) down too.
            stopService()
        }
    }

    companion object {
        private const val REQUEST_CODE = 0x6A75 // "ju"
    }
}
