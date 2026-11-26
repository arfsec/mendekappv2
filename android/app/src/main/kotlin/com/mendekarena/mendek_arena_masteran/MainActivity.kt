package com.mendekarena.mendek_arena_masteran

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val ALARM_CHANNEL = "com.mendekarena.mendek_arena_masteran/alarm"
        private const val REQ_PICK_LOCAL_MEDIA = 9401
    }

    private var alarmChannel: MethodChannel? = null
    private var pendingAlarmPayload: String? = null
    private var pendingMediaPickResult: MethodChannel.Result? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()

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

    override fun onDestroy() {
        AmbientTherapyEngine.stop()
        ioExecutor.shutdown()
        super.onDestroy()
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

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK_LOCAL_MEDIA) return
        val callback = pendingMediaPickResult
        pendingMediaPickResult = null
        if (callback == null) return

        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            callback.success(null)
            return
        }

        ioExecutor.execute {
            try {
                val displayName = resolveDisplayName(uri)
                val lower = displayName.lowercase(Locale.ROOT)
                val ext = lower.substringAfterLast('.', "mp3")
                val safeStem = displayName
                    .substringBeforeLast('.')
                    .replace(Regex("[^A-Za-z0-9._-]"), "_")
                    .ifBlank { "masteran_lokal" }
                val destDir = File(filesDir, "local_masteran")
                if (!destDir.exists()) destDir.mkdirs()
                val destFile = File(destDir, "${System.currentTimeMillis()}_${safeStem}.$ext")

                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(destFile).use { output ->
                        input.copyTo(output, bufferSize = 16 * 1024)
                    }
                } ?: throw IllegalStateException("Tidak dapat membaca file dari penyimpanan.")

                val isAudio = ext in setOf("mp3", "wav", "m4a", "aac", "ogg", "flac", "opus")
                runOnUiThread {
                    callback.success(
                        mapOf(
                            "path" to destFile.absolutePath,
                            "name" to displayName,
                            "isAudioOnly" to isAudio
                        )
                    )
                }
            } catch (e: Exception) {
                runOnUiThread {
                    callback.error("PICK_ERROR", e.message ?: "Gagal menyalin file lokal", null)
                }
            }
        }
    }

    private fun resolveDisplayName(uri: Uri): String {
        var name = ""
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        name = cursor.getString(idx) ?: ""
                    }
                }
            }
        } catch (_: Exception) {
        }
        if (name.isBlank()) {
            name = uri.lastPathSegment?.substringAfterLast('/') ?: "masteran_${System.currentTimeMillis()}.mp3"
        }
        return name
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

                "getAppVersion" -> {
                    try {
                        val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        result.success(pkgInfo.versionName ?: "3.0.0")
                    } catch (_: Exception) {
                        result.success("3.0.0")
                    }
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

                "pickLocalMedia" -> {
                    if (pendingMediaPickResult != null) {
                        result.error("BUSY", "Pemilih file sedang terbuka", null)
                        return@setMethodCallHandler
                    }
                    pendingMediaPickResult = result
                    try {
                        val pickIntent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*"))
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(pickIntent, REQ_PICK_LOCAL_MEDIA)
                    } catch (e: Exception) {
                        pendingMediaPickResult = null
                        result.error("PICK_FAILED", e.message ?: "Tidak bisa membuka pemilih file", null)
                    }
                }

                "startAmbientTherapy" -> {
                    val args = call.arguments as? Map<*, *>
                    val mode = args?.get("mode") as? String ?: "none"
                    val volumePct = (args?.get("volumePct") as? Number)?.toInt() ?: 20
                    AmbientTherapyEngine.start(mode, volumePct)
                    result.success(true)
                }

                "setAmbientVolume" -> {
                    val args = call.arguments as? Map<*, *>
                    val volumePct = (args?.get("volumePct") as? Number)?.toInt() ?: 20
                    AmbientTherapyEngine.setVolume(volumePct)
                    result.success(true)
                }

                "stopAmbientTherapy" -> {
                    AmbientTherapyEngine.stop()
                    result.success(true)
                }

                "setScreenDim" -> {
                    val args = call.arguments as? Map<*, *>
                    val dimmed = args?.get("dimmed") as? Boolean ?: false
                    runOnUiThread {
                        try {
                            val lp = window.attributes
                            lp.screenBrightness = if (dimmed) 0.01f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            window.attributes = lp
                        } catch (_: Exception) {
                        }
                    }
                    result.success(true)
                }

                "getApkUpdateDir" -> {
                    val dir = File(filesDir, "apk_updates")
                    if (!dir.exists()) dir.mkdirs()
                    result.success(dir.absolutePath)
                }

                "installApkFile" -> {
                    val args = call.arguments as? Map<*, *>
                    val rawPath = (args?.get("path") as? String ?: "").trim()
                    if (rawPath.isEmpty()) {
                        result.success(mapOf("started" to false, "error" to "Path APK kosong."))
                        return@setMethodCallHandler
                    }
                    try {
                        val allowedDir = File(filesDir, "apk_updates").canonicalFile
                        val apkFile = File(rawPath).canonicalFile
                        val prefix = allowedDir.path + File.separator
                        if (!apkFile.path.startsWith(prefix) || !apkFile.exists() || !apkFile.name.lowercase(Locale.ROOT).endsWith(".apk")) {
                            result.success(mapOf("started" to false, "error" to "File installer APK tidak valid."))
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            val permIntent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            ).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(permIntent)
                            result.success(mapOf("started" to false, "needsPermission" to true))
                            return@setMethodCallHandler
                        }
                        val apkUri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", apkFile)
                        val installIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(apkUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(installIntent)
                        result.success(mapOf("started" to true))
                    } catch (e: Exception) {
                        result.success(mapOf("started" to false, "error" to (e.message ?: "Gagal membuka installer APK.")))
                    }
                }

                "getDeviceRegionInfo" -> {
                    resolveDeviceRegionInfo(result)
                }
                "shareToSocial" -> {
                    val args = call.arguments as? Map<*, *>
                    val text = (args?.get("text") as? String ?: "").trim()
                    val subject = (args?.get("subject") as? String ?: "Info Mendek Arena").trim()
                    if (text.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val sendIntent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, subject)
                            putExtra(Intent.EXTRA_TEXT, text)
                        }
                        val chooser = Intent.createChooser(sendIntent, "Bagikan ke Media Sosial / WhatsApp")
                        startActivity(chooser)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
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

    private fun resolveDeviceRegionInfo(result: MethodChannel.Result) {
        val hasFine = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasFine && !hasCoarse) {
            result.success(mapOf("permissionDenied" to true))
            return
        }

        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            result.success(mapOf("locationUnavailable" to true))
            return
        }

        fun pickBestLastKnown(): Location? {
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
                LocationManager.PASSIVE_PROVIDER
            )
            var best: Location? = null
            for (provider in providers) {
                try {
                    val loc = lm.getLastKnownLocation(provider)
                    if (loc != null && (best == null || loc.time > best.time)) {
                        best = loc
                    }
                } catch (_: SecurityException) {
                } catch (_: Exception) {
                }
            }
            return best
        }

        fun respondWithLocation(loc: Location) {
            val geocoder = Geocoder(this, Locale("id", "ID"))
            fun sendAddr(addr: Address?) {
                runOnUiThread {
                    result.success(
                        mapOf(
                            "lat" to loc.latitude,
                            "lon" to loc.longitude,
                            "adminArea" to (addr?.adminArea ?: ""),
                            "subAdminArea" to (addr?.subAdminArea ?: ""),
                            "locality" to (addr?.locality ?: ""),
                            "subLocality" to (addr?.subLocality ?: "")
                        )
                    )
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                try {
                    geocoder.getFromLocation(
                        loc.latitude,
                        loc.longitude,
                        1,
                        object : Geocoder.GeocodeListener {
                            override fun onGeocode(addresses: MutableList<Address>) {
                                sendAddr(addresses.firstOrNull())
                            }

                            override fun onError(errorMessage: String?) {
                                sendAddr(null)
                            }
                        }
                    )
                } catch (_: Exception) {
                    sendAddr(null)
                }
            } else {
                ioExecutor.execute {
                    try {
                        @Suppress("DEPRECATION")
                        val list = geocoder.getFromLocation(loc.latitude, loc.longitude, 1)
                        sendAddr(list?.firstOrNull())
                    } catch (_: Exception) {
                        sendAddr(null)
                    }
                }
            }
        }

        val cachedLoc = pickBestLastKnown()
        if (cachedLoc != null) {
            respondWithLocation(cachedLoc)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val provider = when {
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
                lm.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
                else -> null
            }
            if (provider != null) {
                try {
                    lm.getCurrentLocation(provider, null, mainExecutor) { loc ->
                        if (loc != null) {
                            respondWithLocation(loc)
                        } else {
                            result.success(mapOf("locationUnavailable" to true))
                        }
                    }
                    return
                } catch (_: Exception) {
                }
            }
        }

        result.success(mapOf("locationUnavailable" to true))
    }

}
