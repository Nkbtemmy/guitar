package com.thunderzeye.guitaro

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.util.Log
import androidx.annotation.RequiresApi

/// The one capture in progress: an [AudioRecord] fed by the app's own playback, read on a
/// thread and handed to [listener] as 16-bit mono PCM at [SAMPLE_RATE].
object CaptureSession {
    const val SAMPLE_RATE = 44100
    private const val TAG = "PlaybackCapture"

    interface Listener {
        fun onStarted()
        fun onPcm(bytes: ByteArray)
        fun onEnded(error: String?)
    }

    @Volatile
    var listener: Listener? = null
    @Volatile
    var running = false
        private set

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var projection: MediaProjection? = null
    private val main = Handler(Looper.getMainLooper())

    /// Whether [projection] is the one being captured; a stale projection's callbacks are ignored.
    fun owns(projection: MediaProjection) = this.projection === projection

    @RequiresApi(Build.VERSION_CODES.Q)
    fun start(projection: MediaProjection) {
        stop()
        this.projection = projection
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            // Only what this app plays; other apps' sound stays private.
            .addMatchingUid(Process.myUid())
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = try {
            AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minBuffer * 2, 16384))
                .build()
        } catch (e: Exception) {
            listener?.onEnded(e.message ?: "Couldn't open the capture.")
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            listener?.onEnded("Couldn't open the capture.")
            return
        }
        try {
            record.startRecording()
        } catch (e: Exception) {
            record.release()
            listener?.onEnded(e.message ?: "Couldn't start the capture.")
            return
        }
        this.record = record
        running = true
        listener?.onStarted()
        thread = Thread({
            // A starved reader lets the recorder's buffer overrun and drops sound.
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            // 2048 samples: a bit under 50 ms a chunk.
            val buf = ByteArray(4096)
            while (running) {
                val n = record.read(buf, 0, buf.size)
                if (n < 0) {
                    Log.w(TAG, "read failed: $n")
                    // The capture died (audio server restart, projection revoked). End it, or
                    // Flutter and the notification stay stuck on "listening" and every retry is "busy".
                    main.post { if (this.record === record) stop("The capture stopped unexpectedly.") }
                    break
                }
                if (n > 0) listener?.onPcm(buf.copyOf(n))
            }
        }, "playback-capture").also { it.start() }
    }

    fun stop(error: String? = null) {
        val wasRunning = running
        running = false
        // Stopping the recorder first returns a read() in progress, so the join is quick and
        // release() never runs under a read.
        record?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
        }
        thread?.let { if (it != Thread.currentThread()) it.join(500) }
        thread = null
        record?.release()
        record = null
        projection?.stop()
        projection = null
        if (wasRunning) listener?.onEnded(error)
    }
}

/// Foreground service the system requires while a media projection is in use.
class PlaybackCaptureService : Service() {
    private var callback: MediaProjection.Callback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // First, before any way out: a service started with startForegroundService() that stops
        // without having called startForeground() takes the whole app down with it.
        try {
            startInForeground()
        } catch (e: Exception) {
            return fail(e.message ?: "Couldn't start the capture.")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || intent == null) return fail("Capture needs Android 10 or newer.")
        val code = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        @Suppress("DEPRECATION")
        val data: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        if (data == null) return fail("Capture wasn't allowed.")
        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection = try {
            manager.getMediaProjection(code, data)
        } catch (e: Exception) {
            null
        }
        if (projection == null) return fail("The system refused the capture.")
        // Must be registered before the projection is used; also ends the capture when the
        // user stops it from the status bar or locks the screen.
        callback = object : MediaProjection.Callback() {
            override fun onStop() {
                if (!CaptureSession.owns(projection)) return
                CaptureSession.stop()
                stopSelf()
            }
        }.also { projection.registerCallback(it, Handler(Looper.getMainLooper())) }
        CaptureSession.start(projection)
        if (!CaptureSession.running) stopSelf()
        return START_NOT_STICKY
    }

    /// Reports why the capture couldn't start (so Flutter's start() doesn't wait forever) and stops.
    private fun fail(error: String): Int {
        CaptureSession.listener?.onEnded(error)
        stopSelf()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        CaptureSession.stop()
        callback = null
        super.onDestroy()
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Finding chords", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while Guitaro listens to the video it's playing."
            }
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Finding chords")
            .setContentText("Listening to the video playing in Guitaro.")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        private const val CHANNEL_ID = "playback_capture"
        private const val NOTIFICATION_ID = 7201
    }
}
