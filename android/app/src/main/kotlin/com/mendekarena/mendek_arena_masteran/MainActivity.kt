package com.mendekarena.mendek_arena_masteran

import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val ALARM_CHANNEL = "com.mendekarena.mendek_arena_masteran/alarm"
    }

    private var alarmChannel: MethodChannel? = null
    private var pendingAlarmPayload: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableLockScreenWakeFlags()
        super.onCreate(savedInstanceState)
        handleIncomingAlarmIntent(intent, notifyFlutter = false)
    }

    override fun onNewIntent(intent: Intent) {
        enableLockScreenWakeFlags()
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingAlarmIntent(intent, notifyFlutter = true)
    }

    private fun enableLockScreenWakeFlags() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            try {
                if (km != null && !km.isKeyguardSecure) {
                    km.requestDismissKeyguard(this, null)
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun handleIncomingAlarmIntent(intent: Intent?, notifyFlutter: Boolean) {
        if (intent == null) return
        if (intent.action == MasteranAlarmReceiver.ACTION_FIRE_ALARM) {
            val payload = intent.getStringExtra(MasteranAlarmReceiver.EXTRA_PAYLOAD)
            if (!payload.isNullOrEmpty()) {
                // Keep MasteranAlarmService alive until PlayerScreen transitions or stops
                pendingAlarmPayload = payload
                if (notifyFlutter && alarmChannel != null) {
                    alarmChannel?.invokeMethod("onAlarmTriggered", payload, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (result == true) {
                                pendingAlarmPayload = null
                            }
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        }

                        override fun notImplemented() {
                        }
                    })
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ALARM_CHANNEL
        )
        alarmChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ping" -> {
                    result.success(true)
                }

                "getBatterySnapshot" -> {
                    try {
                        val snap = BatteryGuardHelper.readSnapshot(applicationContext)
                        result.success(
                            mapOf(
                                "levelPct" to snap.levelPct,
                                "isCharging" to snap.isCharging,
                                "tempCelsius" to snap.tempCelsius
                            )
                        )
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }

                "scheduleWeeklyAlarm" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("INVALID_ARGS", "Missing arguments", null)
                        return@setMethodCallHandler
                    }
                    val requestCode = (args["requestCode"] as Number).toInt()
                    val triggerAtMillis = (args["triggerAtMillis"] as Number).toLong()
                    val weekday = (args["weekday"] as Number).toInt()
                    val hour = (args["hour"] as Number).toInt()
                    val minute = (args["minute"] as Number).toInt()
                    val title = args["title"] as? String ?: "Masteran Burung"
                    val body = args["body"] as? String ?: "Waktunya masteran"
                    val payload = args["payload"] as? String ?: ""

                    MasteranAlarmReceiver.scheduleAlarmClockInternal(
                        context = applicationContext,
                        requestCode = requestCode,
                        triggerAtMillis = triggerAtMillis,
                        weekday = weekday,
                        hour = hour,
                        minute = minute,
                        title = title,
                        body = body,
                        payload = payload,
                        isRepeating = true,
                        persist = true
                    )
                    result.success(true)
                }

                "scheduleOneShotAlarm" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("INVALID_ARGS", "Missing arguments", null)
                        return@setMethodCallHandler
                    }
                    val requestCode = (args["requestCode"] as Number).toInt()
                    val triggerAtMillis = (args["triggerAtMillis"] as Number).toLong()
                    val title = args["title"] as? String ?: "Tes Alarm Masteran"
                    val body = args["body"] as? String ?: "Memutar masteran otomatis..."
                    val payload = args["payload"] as? String ?: ""

                    MasteranAlarmReceiver.scheduleAlarmClockInternal(
                        context = applicationContext,
                        requestCode = requestCode,
                        triggerAtMillis = triggerAtMillis,
                        weekday = 0,
                        hour = -1,
                        minute = -1,
                        title = title,
                        body = body,
                        payload = payload,
                        isRepeating = false,
                        persist = false
                    )
                    result.success(true)
                }

                "cancelAlarm" -> {
                    val args = call.arguments as? Map<*, *>
                    val requestCode = (args?.get("requestCode") as? Number)?.toInt() ?: 0
                    MasteranAlarmReceiver.cancelAlarmInternal(applicationContext, requestCode)
                    result.success(true)
                }

                "cancelAllAlarms" -> {
                    MasteranAlarmReceiver.cancelAllAlarmsInternal(applicationContext)
                    result.success(true)
                }

                "getInitialAlarmPayload" -> {
                    val payload = pendingAlarmPayload
                    pendingAlarmPayload = null
                    result.success(payload)
                }

                "clearAlarmNotification" -> {
                    MasteranAlarmReceiver.clearActiveAlarmNotification(applicationContext, forceStopService = false)
                    result.success(true)
                }
                "startPlaybackForegroundService" -> {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: "Masteran Burung Berjalan"
                    val body = args?.get("body") as? String ?: "Audio masteran aktif di latar belakang & lockscreen"
                    val payload = args?.get("payload") as? String ?: ""
                    val serviceIntent = Intent(applicationContext, MasteranAlarmService::class.java).apply {
                        action = MasteranAlarmService.ACTION_START_KEEPALIVE
                        putExtra(MasteranAlarmReceiver.EXTRA_TITLE, title)
                        putExtra(MasteranAlarmReceiver.EXTRA_BODY, body)
                        putExtra(MasteranAlarmReceiver.EXTRA_PAYLOAD, payload)
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            applicationContext.startForegroundService(serviceIntent)
                        } else {
                            applicationContext.startService(serviceIntent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopPlaybackForegroundService" -> {
                    val stopIntent = Intent(applicationContext, MasteranAlarmService::class.java).apply {
                        action = MasteranAlarmService.ACTION_STOP_SERVICE
                    }
                    try {
                        applicationContext.startService(stopIntent)
                    } catch (_: Exception) {
                        MasteranAlarmReceiver.clearActiveAlarmNotification(applicationContext, forceStopService = true)
                    }
                    result.success(true)
                }
                "ensureBackgroundFallbackAudio" -> {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: "Masteran Burung Berjalan"
                    val body = args?.get("body") as? String ?: "Audio masteran tetap berbunyi di latar belakang"
                    val payload = args?.get("payload") as? String ?: ""
                    val serviceIntent = Intent(applicationContext, MasteranAlarmService::class.java).apply {
                        action = MasteranAlarmService.ACTION_ENSURE_BACKGROUND_AUDIO
                        putExtra(MasteranAlarmReceiver.EXTRA_TITLE, title)
                        putExtra(MasteranAlarmReceiver.EXTRA_BODY, body)
                        putExtra(MasteranAlarmReceiver.EXTRA_PAYLOAD, payload)
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            applicationContext.startForegroundService(serviceIntent)
                        } else {
                            applicationContext.startService(serviceIntent)
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "startStandbyService" -> {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: "Mendek Arena — Siaga Alarm"
                    val body = args?.get("body") as? String ?: "Tetap berjalan di latar belakang meski aplikasi ditutup"
                    val serviceIntent = Intent(applicationContext, MasteranAlarmService::class.java).apply {
                        action = MasteranAlarmService.ACTION_START_STANDBY
                        putExtra(MasteranAlarmReceiver.EXTRA_TITLE, title)
                        putExtra(MasteranAlarmReceiver.EXTRA_BODY, body)
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            applicationContext.startForegroundService(serviceIntent)
                        } else {
                            applicationContext.startService(serviceIntent)
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "stopStandbyService" -> {
                    val serviceIntent = Intent(applicationContext, MasteranAlarmService::class.java).apply {
                        action = MasteranAlarmService.ACTION_STOP_STANDBY
                    }
                    try {
                        applicationContext.startService(serviceIntent)
                    } catch (_: Exception) {
                    }
                    result.success(true)
                }

                "canUseFullScreenIntent" -> {
                    if (Build.VERSION.SDK_INT >= 34) {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        result.success(nm.canUseFullScreenIntent())
                    } else {
                        result.success(true)
                    }
                }

                "openFullScreenIntentSettings" -> {
                    if (Build.VERSION.SDK_INT >= 34) {
                        try {
                            val settingsIntent = Intent(
                                "android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT",
                                Uri.parse("package:$packageName")
                            ).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(settingsIntent)
                            result.success(true)
                            return@setMethodCallHandler
                        } catch (_: Exception) {
                        }
                    }
                    openAppDetailsSettingsInternal()
                    result.success(true)
                }

                "openAppDetailsSettings" -> {
                    openAppDetailsSettingsInternal()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun openAppDetailsSettingsInternal() {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            ).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
        } catch (_: Exception) {
        }
    }
}
