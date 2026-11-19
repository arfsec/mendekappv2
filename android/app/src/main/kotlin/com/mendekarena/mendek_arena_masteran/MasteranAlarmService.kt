package com.mendekarena.mendek_arena_masteran

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

class MasteranAlarmService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var isStopped = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(MasteranAlarmReceiver.EXTRA_TITLE)
            ?: "Masteran Burung Otomatis"
        val body = intent?.getStringExtra(MasteranAlarmReceiver.EXTRA_BODY)
            ?: "Memutar masteran otomatis..."
        val payload = intent?.getStringExtra(MasteranAlarmReceiver.EXTRA_PAYLOAD) ?: ""
        val requestCode = intent?.getIntExtra(MasteranAlarmReceiver.EXTRA_REQUEST_CODE, 99001) ?: 99001

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

        if (payload.isNotEmpty()) {
            acquireTemporaryWakeLock()
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
                if (!isStopped) {
                    MasteranAlarmReceiver.tryLaunchActivity(this, launchIntent, fullScreenPi)
                }
            }, 1500L)

            handler.postDelayed({
                stopSelfSafely()
            }, 25_000L)
        } else {
            stopSelfSafely()
        }

        return START_NOT_STICKY
    }

    private fun acquireTemporaryWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "MendekArena:AlarmServiceWake"
            ).apply {
                acquire(30_000L)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopSelfSafely() {
        isStopped = true
        handler.removeCallbacksAndMessages(null)
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
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
        handler.removeCallbacksAndMessages(null)
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }
}
