package com.mendekarena.mendek_arena_masteran

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import java.io.File
import java.io.FileOutputStream
import java.util.Calendar
import kotlin.math.PI
import kotlin.math.sin

class MasteranAlarmService : Service() {
    companion object {
        const val ACTION_START_STANDBY = "com.mendekarena.mendek_arena_masteran.ACTION_START_STANDBY"
        const val ACTION_STOP_STANDBY = "com.mendekarena.mendek_arena_masteran.ACTION_STOP_STANDBY"
        const val ACTION_START_KEEPALIVE = "com.mendekarena.mendek_arena_masteran.ACTION_START_KEEPALIVE"
        const val ACTION_ENSURE_BACKGROUND_AUDIO = "com.mendekarena.mendek_arena_masteran.ACTION_ENSURE_BACKGROUND_AUDIO"
        const val ACTION_STOP_SERVICE = "com.mendekarena.mendek_arena_masteran.ACTION_STOP_SERVICE"
        const val EXTRA_LOCAL_PATH = "alarm_local_path"
        const val PREF_STANDBY_ENABLED = "standby_bg_enabled"
        const val PREF_STANDBY_TITLE = "standby_bg_title"
        const val PREF_STANDBY_BODY = "standby_bg_body"

        @Volatile
        var isKeepAliveByPlayer: Boolean = false

        fun isStandbyEnabled(context: Context): Boolean {
            val prefs = context.getSharedPreferences(MasteranAlarmReceiver.PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getBoolean(PREF_STANDBY_ENABLED, false)
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var fallbackPlayer: MediaPlayer? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var isStopped = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            if (isStandbyEnabled(this)) {
                val prefs = getSharedPreferences(MasteranAlarmReceiver.PREFS_NAME, Context.MODE_PRIVATE)
                val sTitle = prefs.getString(PREF_STANDBY_TITLE, "Mendek Arena — Siaga Alarm") ?: "Mendek Arena — Siaga Alarm"
                val sBody = prefs.getString(PREF_STANDBY_BODY, "Jadwal masteran siap berbunyi otomatis") ?: "Jadwal masteran siap berbunyi otomatis"
                if (startForegroundStandbySafe(sTitle, sBody)) {
                    return START_STICKY
                }
            }
            stopSelfSafely()
            return START_NOT_STICKY
        }

        val action = intent.action ?: ""
        if (action == ACTION_STOP_SERVICE) {
            isKeepAliveByPlayer = false
            stopFallbackPlayer()
            abandonAudioFocus()
            releaseLocks()
            handler.removeCallbacksAndMessages(null)
            if (isStandbyEnabled(this)) {
                val prefs = getSharedPreferences(MasteranAlarmReceiver.PREFS_NAME, Context.MODE_PRIVATE)
                val sTitle = prefs.getString(PREF_STANDBY_TITLE, "Mendek Arena — Siaga Alarm") ?: "Mendek Arena — Siaga Alarm"
                val sBody = prefs.getString(PREF_STANDBY_BODY, "Jadwal masteran siap berbunyi otomatis") ?: "Jadwal masteran siap berbunyi otomatis"
                if (startForegroundStandbySafe(sTitle, sBody)) {
                    return START_STICKY
                }
            }
            stopSelfSafely()
            return START_NOT_STICKY
        }

        if (action == ACTION_STOP_STANDBY) {
            saveStandbyPref(false, "", "")
            if (!isKeepAliveByPlayer && fallbackPlayer == null) {
                stopSelfSafely()
            }
            return START_NOT_STICKY
        }

        val title = intent.getStringExtra(MasteranAlarmReceiver.EXTRA_TITLE)
            ?: "Masteran Burung Berjalan"
        val body = intent.getStringExtra(MasteranAlarmReceiver.EXTRA_BODY)
            ?: "Tetap berbunyi di layar belakang meski aplikasi ditutup."

        if (action == ACTION_START_STANDBY) {
            saveStandbyPref(true, title, body)
            if (!isKeepAliveByPlayer && fallbackPlayer == null) {
                if (!startForegroundStandbySafe(title, body)) {
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            return START_STICKY
        }

        val payload = intent.getStringExtra(MasteranAlarmReceiver.EXTRA_PAYLOAD) ?: ""
        val requestCode = intent.getIntExtra(MasteranAlarmReceiver.EXTRA_REQUEST_CODE, 99001)
        val localPath = intent.getStringExtra(EXTRA_LOCAL_PATH) ?: extractLocalPathFromPayload(payload)

        if (!startForegroundAlarmSafe(requestCode, title, body, payload)) {
            stopSelf()
            return START_NOT_STICKY
        }

        isStopped = false
        acquirePersistentLocks()

        if (action == ACTION_START_KEEPALIVE) {
            isKeepAliveByPlayer = true
            handler.removeCallbacksAndMessages(null)
            stopFallbackPlayer()
            return START_STICKY
        }

        if (action == ACTION_ENSURE_BACKGROUND_AUDIO) {
            isKeepAliveByPlayer = false
            handler.removeCallbacksAndMessages(null)
            startNativeBackgroundAudio(localPath)
            scheduleAutoStopFromPayload(payload)
            return START_STICKY
        }

        // Alarm fired (even when app is closed & screen locked)
        isKeepAliveByPlayer = false
        if (payload.isNotEmpty()) {
            val launchIntent = MasteranAlarmReceiver.buildLaunchIntent(this, payload, title)
            val fullScreenPi = PendingIntent.getActivity(
                this,
                requestCode,
                launchIntent,
                MasteranAlarmReceiver.pendingIntentFlags()
            )
            MasteranAlarmReceiver.tryLaunchActivity(this, launchIntent, fullScreenPi)

            handler.removeCallbacksAndMessages(null)
            handler.postDelayed({
                if (!isStopped && !isKeepAliveByPlayer) {
                    MasteranAlarmReceiver.tryLaunchActivity(this, launchIntent, fullScreenPi)
                }
            }, 1200L)

            // If app is closed/locked and UI didn't take over within 2.5s, play audio directly in background!
            handler.postDelayed({
                if (!isStopped && !isKeepAliveByPlayer) {
                    startNativeBackgroundAudio(localPath)
                }
            }, 2500L)

            scheduleAutoStopFromPayload(payload)
        }

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Keep alarm service alive in background if user swipes the app away from Recent Apps
        super.onTaskRemoved(rootIntent)
    }

    private fun saveStandbyPref(enabled: Boolean, title: String, body: String) {
        val prefs = getSharedPreferences(MasteranAlarmReceiver.PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(PREF_STANDBY_ENABLED, enabled)
            .putString(PREF_STANDBY_TITLE, title)
            .putString(PREF_STANDBY_BODY, body)
            .apply()
    }

    private fun startForegroundStandbySafe(title: String, body: String): Boolean {
        return try {
            val notif = MasteranAlarmReceiver.buildStandbyNotification(this, title, body)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    MasteranAlarmReceiver.STANDBY_NOTIF_ID,
                    notif,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(MasteranAlarmReceiver.STANDBY_NOTIF_ID, notif)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun startForegroundAlarmSafe(
        requestCode: Int,
        title: String,
        body: String,
        payload: String
    ): Boolean {
        return try {
            val notification = MasteranAlarmReceiver.buildAlarmNotification(
                context = this,
                requestCode = requestCode,
                title = title,
                body = body,
                payload = payload
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    MasteranAlarmReceiver.ALARM_NOTIF_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(MasteranAlarmReceiver.ALARM_NOTIF_ID, notification)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun extractLocalPathFromPayload(payload: String): String {
        val parts = payload.split("|")
        if (parts.size >= 6) {
            return parts[5].trim()
        }
        return ""
    }

    private fun scheduleAutoStopFromPayload(payload: String) {
        val parts = payload.split("|")
        var durationMs = 15 * 60 * 1000L
        val isTest = parts.size >= 5 && parts[4] == "TEST"
        if (!isTest && parts.size >= 3 && parts[2].contains(":")) {
            val hm = parts[2].split(":")
            val endHour = hm[0].toIntOrNull()
            val endMin = hm.getOrNull(1)?.toIntOrNull()
            if (endHour != null && endMin != null) {
                val now = System.currentTimeMillis()
                val cal = Calendar.getInstance().apply {
                    set(Calendar.HOUR_OF_DAY, endHour)
                    set(Calendar.MINUTE, endMin)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                }
                if (cal.timeInMillis <= now) {
                    cal.add(Calendar.DAY_OF_YEAR, 1)
                }
                val diff = cal.timeInMillis - now
                if (diff in 5_000L..(12 * 60 * 60 * 1000L)) {
                    durationMs = diff
                }
            }
        }
        handler.postDelayed({
            if (!isStopped && !isKeepAliveByPlayer) {
                val stopIntent = Intent(this, MasteranAlarmService::class.java).apply {
                    action = ACTION_STOP_SERVICE
                }
                startService(stopIntent)
            }
        }, durationMs)
    }

    private fun requestAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .build()
                audioFocusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(null, AudioManager.STREAM_ALARM, AudioManager.AUDIOFOCUS_GAIN)
            }
        } catch (_: Exception) {
        }
    }

    private fun abandonAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
                audioFocusRequest = null
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        } catch (_: Exception) {
        }
    }

    private fun ensureSynthBirdAlarmWav(): File {
        val outFile = File(cacheDir, "mendek_masteran_alarm_v2.wav")
        if (outFile.exists() && outFile.length() > 10_000L) {
            return outFile
        }
        val sampleRate = 22050
        val durationSec = 4
        val totalSamples = sampleRate * durationSec
        val pcm = ByteArray(totalSamples * 2)

        for (i in 0 until totalSamples) {
            val t = i.toDouble() / sampleRate.toDouble()
            // Burst envelope (Cililin & Kenari rapid trill + soft alarm chime pulse)
            val cycle = t % 1.0
            val burstEnv = when {
                cycle < 0.35 -> sin(PI * (cycle / 0.35))
                cycle in 0.45..0.80 -> sin(PI * ((cycle - 0.45) / 0.35))
                else -> 0.08
            }
            val vibrato = sin(2.0 * PI * 36.0 * t)
            val freqBird = 3400.0 + 750.0 * vibrato
            val chirp = sin(2.0 * PI * freqBird * t) * 0.55 + sin(2.0 * PI * (freqBird * 1.48) * t) * 0.25
            val chime = sin(2.0 * PI * 880.0 * t) * 0.15
            val sampleVal = ((chirp * burstEnv + chime * 0.35) * 22000.0).toInt().coerceIn(-32767, 32767)
            pcm[i * 2] = (sampleVal and 0xFF).toByte()
            pcm[i * 2 + 1] = ((sampleVal shr 8) and 0xFF).toByte()
        }

        val dataSize = pcm.size
        val byteRate = sampleRate * 2
        val header = byteArrayOf(
            'R'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), 'F'.code.toByte(),
            ((dataSize + 36) and 0xFF).toByte(), (((dataSize + 36) shr 8) and 0xFF).toByte(),
            (((dataSize + 36) shr 16) and 0xFF).toByte(), (((dataSize + 36) shr 24) and 0xFF).toByte(),
            'W'.code.toByte(), 'A'.code.toByte(), 'V'.code.toByte(), 'E'.code.toByte(),
            'f'.code.toByte(), 'm'.code.toByte(), 't'.code.toByte(), ' '.code.toByte(),
            16, 0, 0, 0,
            1, 0,
            1, 0,
            (sampleRate and 0xFF).toByte(), ((sampleRate shr 8) and 0xFF).toByte(),
            ((sampleRate shr 16) and 0xFF).toByte(), ((sampleRate shr 24) and 0xFF).toByte(),
            (byteRate and 0xFF).toByte(), ((byteRate shr 8) and 0xFF).toByte(),
            ((byteRate shr 16) and 0xFF).toByte(), ((byteRate shr 24) and 0xFF).toByte(),
            2, 0,
            16, 0,
            'd'.code.toByte(), 'a'.code.toByte(), 't'.code.toByte(), 'a'.code.toByte(),
            (dataSize and 0xFF).toByte(), ((dataSize shr 8) and 0xFF).toByte(),
            ((dataSize shr 16) and 0xFF).toByte(), ((dataSize shr 24) and 0xFF).toByte()
        )
        FileOutputStream(outFile).use { fos ->
            fos.write(header)
            fos.write(pcm)
        }
        return outFile
    }

    private fun startNativeBackgroundAudio(localPath: String) {
        if (fallbackPlayer != null) return
        requestAudioFocus()
        try {
            val offlineFile = if (localPath.isNotEmpty()) File(localPath) else null
            val sourceFile = if (offlineFile != null && offlineFile.exists()) {
                offlineFile
            } else {
                ensureSynthBirdAlarmWav()
            }
            val player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                setWakeMode(applicationContext, PowerManager.PARTIAL_WAKE_LOCK)
                setDataSource(sourceFile.absolutePath)
                isLooping = true
                prepare()
                start()
            }
            fallbackPlayer = player
        } catch (_: Exception) {
            stopFallbackPlayer()
        }
    }

    private fun stopFallbackPlayer() {
        try {
            fallbackPlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            fallbackPlayer?.release()
        } catch (_: Exception) {
        }
        fallbackPlayer = null
    }

    private fun acquirePersistentLocks() {
        try {
            if (wakeLock?.isHeld != true) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "MendekArena:PlaybackWakeLock"
                ).apply {
                    acquire(4 * 60 * 60 * 1000L)
                }
            }
        } catch (_: Exception) {
        }
        try {
            if (wifiLock?.isHeld != true) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "MendekArena:PlaybackWifiLock").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {
        }
        wifiLock = null
    }

    private fun stopSelfSafely() {
        isStopped = true
        isKeepAliveByPlayer = false
        handler.removeCallbacksAndMessages(null)
        stopFallbackPlayer()
        abandonAudioFocus()
        releaseLocks()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        isStopped = true
        isKeepAliveByPlayer = false
        handler.removeCallbacksAndMessages(null)
        stopFallbackPlayer()
        abandonAudioFocus()
        releaseLocks()
        super.onDestroy()
    }
}
