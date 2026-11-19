package com.mendekarena.mendek_arena_masteran

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

class MasteranBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            val prefs = context.getSharedPreferences(
                MasteranAlarmReceiver.PREFS_NAME,
                Context.MODE_PRIVATE
            )
            val entries = prefs.all
            for ((_, rawVal) in entries) {
                val rawStr = rawVal as? String ?: continue
                try {
                    val obj = JSONObject(rawStr)
                    val requestCode = obj.getInt("requestCode")
                    val weekday = obj.getInt("weekday")
                    val hour = obj.getInt("hour")
                    val minute = obj.getInt("minute")
                    val title = obj.optString("title", "Masteran Burung Otomatis")
                    val body = obj.optString("body", "Memutar jadwal masteran...")
                    val payload = obj.optString("payload", "")
                    if (payload.isNotEmpty() && weekday in 1..7 && hour in 0..23 && minute in 0..59) {
                        val triggerMillis = MasteranAlarmReceiver.computeNextWeeklyTriggerMillis(
                            weekday,
                            hour,
                            minute
                        )
                        MasteranAlarmReceiver.scheduleAlarmClockInternal(
                            context = context,
                            requestCode = requestCode,
                            triggerAtMillis = triggerMillis,
                            weekday = weekday,
                            hour = hour,
                            minute = minute,
                            title = title,
                            body = body,
                            payload = payload,
                            isRepeating = true,
                            persist = false
                        )
                    }
                } catch (_: Exception) {
                }
            }
        }
    }
}
