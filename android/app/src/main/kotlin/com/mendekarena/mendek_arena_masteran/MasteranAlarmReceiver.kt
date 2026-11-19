package com.mendekarena.mendek_arena_masteran

import android.app.ActivityOptions
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import org.json.JSONObject
import java.util.Calendar

class MasteranAlarmReceiver : BroadcastReceiver() {

    companion object {
        const val PREFS_NAME = "mendek_native_alarms"
        const val ACTION_FIRE_ALARM = "com.mendekarena.mendek_arena_masteran.ACTION_FIRE_ALARM"
        const val EXTRA_REQUEST_CODE = "alarm_request_code"
        const val EXTRA_TITLE = "alarm_title"
        const val EXTRA_BODY = "alarm_body"
        const val EXTRA_PAYLOAD = "alarm_payload"
        const val EXTRA_WEEKDAY = "alarm_weekday"
        const val EXTRA_HOUR = "alarm_hour"
        const val EXTRA_MINUTE = "alarm_minute"
        const val EXTRA_REPEATING = "alarm_repeating"
        const val ALARM_CHANNEL_ID = "mendek_alarm_ring_v2"
        const val ALARM_NOTIF_ID = 99001

        fun pendingIntentFlags(): Int {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        }

        fun buildBalAllowedBundle(): Bundle? {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ActivityOptions.makeBasic().apply {
                    setPendingIntentBackgroundActivityStartMode(
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                    )
                }.toBundle()
            } else {
                null
            }
        }

        fun buildLaunchIntent(context: Context, payload: String, title: String): Intent {
            return Intent(context, MainActivity::class.java).apply {
                action = ACTION_FIRE_ALARM
                putExtra(EXTRA_PAYLOAD, payload)
                putExtra(EXTRA_TITLE, title)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        }

        fun tryLaunchActivity(
            context: Context,
            launchIntent: Intent,
            fullScreenPendingIntent: PendingIntent
        ) {
            val balBundle = buildBalAllowedBundle()
            val canOverlay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Settings.canDrawOverlays(context)
            } else {
                true
            }

            if (canOverlay || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                try {
                    if (balBundle != null) {
                        context.startActivity(launchIntent, balBundle)
                    } else {
                        context.startActivity(launchIntent)
                    }
                    return
                } catch (_: Exception) {
                }
            }

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && balBundle != null) {
                    fullScreenPendingIntent.send(context, 0, null, null, null, null, balBundle)
                } else {
                    fullScreenPendingIntent.send()
                }
            } catch (_: Exception) {
            }
        }

        fun ensureAlarmChannel(context: Context): NotificationManager {
            val notifManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val existing = notifManager.getNotificationChannel(ALARM_CHANNEL_ID)
                if (existing == null) {
                    val channel = NotificationChannel(
                        ALARM_CHANNEL_ID,
                        "Alarm Otomatis Masteran Burung",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description =
                            "Membuka pemutar video masteran secara otomatis saat jadwal tiba"
                        enableVibration(true)
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                        setBypassDnd(true)
                        val soundUri =
                            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                        setSound(
                            soundUri,
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ALARM)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                        )
                    }
                    notifManager.createNotificationChannel(channel)
                }
            }
            return notifManager
        }

        fun buildAlarmNotification(
            context: Context,
            requestCode: Int,
            title: String,
            body: String,
            payload: String
        ): Notification {
            ensureAlarmChannel(context)
            val launchIntent = buildLaunchIntent(context, payload, title)
            val fullScreenPendingIntent = PendingIntent.getActivity(
                context,
                requestCode,
                launchIntent,
                pendingIntentFlags()
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, ALARM_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
                    .setPriority(Notification.PRIORITY_MAX)
            }

            val appIcon = context.applicationInfo.icon
            builder
                .setSmallIcon(if (appIcon != 0) appIcon else android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_ALARM)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setContentIntent(fullScreenPendingIntent)
                .setFullScreenIntent(fullScreenPendingIntent, true)

            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                @Suppress("DEPRECATION")
                builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
            }

            return builder.build()
        }

        fun computeNextWeeklyTriggerMillis(weekday: Int, hour: Int, minute: Int): Long {
            val targetCalDay = if (weekday == 7) Calendar.SUNDAY else weekday + 1
            val now = System.currentTimeMillis()
            val cal = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            while (cal.get(Calendar.DAY_OF_WEEK) != targetCalDay || cal.timeInMillis <= now + 5_000L) {
                cal.add(Calendar.DAY_OF_YEAR, 1)
            }
            return cal.timeInMillis
        }

        fun scheduleAlarmClockInternal(
            context: Context,
            requestCode: Int,
            triggerAtMillis: Long,
            weekday: Int,
            hour: Int,
            minute: Int,
            title: String,
            body: String,
            payload: String,
            isRepeating: Boolean,
            persist: Boolean
        ) {
            if (persist && isRepeating) {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val obj = JSONObject().apply {
                    put("requestCode", requestCode)
                    put("weekday", weekday)
                    put("hour", hour)
                    put("minute", minute)
                    put("title", title)
                    put("body", body)
                    put("payload", payload)
                }
                prefs.edit().putString(requestCode.toString(), obj.toString()).apply()
            }

            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

            val receiverIntent = Intent(context, MasteranAlarmReceiver::class.java).apply {
                action = ACTION_FIRE_ALARM
                putExtra(EXTRA_REQUEST_CODE, requestCode)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
                putExtra(EXTRA_PAYLOAD, payload)
                putExtra(EXTRA_WEEKDAY, weekday)
                putExtra(EXTRA_HOUR, hour)
                putExtra(EXTRA_MINUTE, minute)
                putExtra(EXTRA_REPEATING, isRepeating)
            }
            val alarmPendingIntent = PendingIntent.getBroadcast(
                context,
                requestCode,
                receiverIntent,
                pendingIntentFlags()
            )

            val showActivityIntent = buildLaunchIntent(context, payload, title)
            val showPendingIntent = PendingIntent.getActivity(
                context,
                requestCode,
                showActivityIntent,
                pendingIntentFlags()
            )

            val safeTrigger = maxOf(triggerAtMillis, System.currentTimeMillis() + 1_500L)

            try {
                val clockInfo = AlarmManager.AlarmClockInfo(safeTrigger, showPendingIntent)
                alarmManager.setAlarmClock(clockInfo, alarmPendingIntent)
            } catch (_: SecurityException) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        safeTrigger,
                        alarmPendingIntent
                    )
                } else {
                    alarmManager.set(AlarmManager.RTC_WAKEUP, safeTrigger, alarmPendingIntent)
                }
            }
        }

        fun cancelAlarmInternal(context: Context, requestCode: Int, removeFromPrefs: Boolean = true) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, MasteranAlarmReceiver::class.java).apply {
                action = ACTION_FIRE_ALARM
            }
            val pi = PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                pendingIntentFlags()
            )
            alarmManager.cancel(pi)
            pi.cancel()

            if (removeFromPrefs) {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                prefs.edit().remove(requestCode.toString()).apply()
            }
        }

        fun cancelAllAlarmsInternal(context: Context) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val allKeys = prefs.all.keys.toList()
            for (k in allKeys) {
                val code = k.toIntOrNull()
                if (code != null) {
                    cancelAlarmInternal(context, code, removeFromPrefs = false)
                }
            }
            prefs.edit().clear().apply()
        }

        fun clearActiveAlarmNotification(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(ALARM_NOTIF_ID)
            try {
                context.stopService(Intent(context, MasteranAlarmService::class.java))
            } catch (_: Exception) {
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return

        val requestCode = intent.getIntExtra(EXTRA_REQUEST_CODE, 0)
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Masteran Burung Otomatis"
        val body = intent.getStringExtra(EXTRA_BODY) ?: "Memutar jadwal masteran..."
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        val weekday = intent.getIntExtra(EXTRA_WEEKDAY, 0)
        val hour = intent.getIntExtra(EXTRA_HOUR, -1)
        val minute = intent.getIntExtra(EXTRA_MINUTE, -1)
        val isRepeating = intent.getBooleanExtra(EXTRA_REPEATING, false)

        if (payload.isEmpty()) return

        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val cpuWake = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "MendekArena:AlarmCpuWake"
        )
        try {
            cpuWake.acquire(15_000L)
        } catch (_: Exception) {
        }

        @Suppress("DEPRECATION")
        try {
            val screenWake = powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "MendekArena:AlarmScreenWake"
            )
            screenWake.acquire(12_000L)
        } catch (_: Exception) {
        }

        val notifManager = ensureAlarmChannel(context)
        val notification = buildAlarmNotification(
            context = context,
            requestCode = requestCode,
            title = title,
            body = body,
            payload = payload
        )
        notifManager.notify(ALARM_NOTIF_ID, notification)

        val launchIntent = buildLaunchIntent(context, payload, title)
        val fullScreenPendingIntent = PendingIntent.getActivity(
            context,
            requestCode,
            launchIntent,
            pendingIntentFlags()
        )
        tryLaunchActivity(context, launchIntent, fullScreenPendingIntent)

        // Jalankan Foreground Service sebagai pengawal agar tidak dibunuh OS dan menyalakan ringtone cadangan bila layar diblokir OEM
        try {
            val serviceIntent = Intent(context, MasteranAlarmService::class.java).apply {
                putExtra(EXTRA_REQUEST_CODE, requestCode)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
                putExtra(EXTRA_PAYLOAD, payload)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (_: Exception) {
        }

        if (isRepeating && weekday in 1..7 && hour in 0..23 && minute in 0..59) {
            val nextTrigger = computeNextWeeklyTriggerMillis(weekday, hour, minute)
            scheduleAlarmClockInternal(
                context = context,
                requestCode = requestCode,
                triggerAtMillis = nextTrigger,
                weekday = weekday,
                hour = hour,
                minute = minute,
                title = title,
                body = body,
                payload = payload,
                isRepeating = true,
                persist = true
            )
        }
    }
}
