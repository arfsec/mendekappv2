package com.mendekarena.mendek_arena_masteran

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.os.Environment
import android.os.Handler
import android.os.Looper
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONObject
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

                "scanMusicBoxes" -> {
                    scanMusicBoxesBle(result)
                }

                "syncMusicBoxBle" -> {
                    val args = call.arguments as? Map<*, *>
                    val address = (args?.get("address") as? String ?: "").trim()
                    val payloadJson = (args?.get("payloadJson") as? String ?: "").trim()
                    syncMusicBoxBleInternal(address, payloadJson, result)
                }

                "encryptFileToMbx" -> {
                    val args = call.arguments as? Map<*, *>
                    val srcPath = (args?.get("srcPath") as? String ?: "").trim()
                    val fileName = (args?.get("fileName") as? String ?: "masteran.mbx").trim()
                    val boxKey = (args?.get("boxKey") as? String ?: "").trim()
                    val boxDeviceId = (args?.get("boxDeviceId") as? String ?: "").trim()
                    encryptFileToMbxInternal(srcPath, fileName, boxKey, boxDeviceId, result)
                }

                else -> result.notImplemented()
            }
        }
    }


    private fun hasBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    @SuppressLint("MissingPermission")
    private fun scanMusicBoxesBle(result: MethodChannel.Result) {
        if (!hasBlePermissions()) {
            result.error("NO_BLE_PERM", "Izin Bluetooth belum diberikan.", null)
            return
        }
        val btMgr = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter: BluetoothAdapter? = btMgr?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth HP dalam keadaan mati. Nyalakan Bluetooth dulu.", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.error("NO_SCANNER", "Pemindai BLE tidak tersedia di perangkat ini.", null)
            return
        }

        val foundMap = ConcurrentHashMap<String, Map<String, Any>>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scanResult: ScanResult) {
                val dev = scanResult.device ?: return
                val addr = dev.address ?: return
                val name = dev.name ?: scanResult.scanRecord?.deviceName ?: ""
                if (name.isBlank()) return
                val isMendek = name.contains("MendekBox", ignoreCase = true)
                foundMap[addr] = mapOf(
                    "address" to addr,
                    "name" to name,
                    "rssi" to scanResult.rssi,
                    "isMendekBox" to isMendek
                )
            }
        }

        try {
            scanner.startScan(cb)
        } catch (e: Exception) {
            result.error("SCAN_ERR", e.message ?: "Gagal memulai scan Bluetooth.", null)
            return
        }

        Handler(Looper.getMainLooper()).postDelayed({
            try {
                scanner.stopScan(cb)
            } catch (_: Exception) {
            }
            val list = foundMap.values.sortedWith(
                compareByDescending<Map<String, Any>> { it["isMendekBox"] == true }
                    .thenByDescending { (it["rssi"] as? Int) ?: -100 }
            )
            result.success(list)
        }, 3500)
    }

    @SuppressLint("MissingPermission")
    private fun syncMusicBoxBleInternal(
        address: String,
        payloadJson: String,
        result: MethodChannel.Result
    ) {
        if (!hasBlePermissions()) {
            result.success(mapOf("ok" to false, "error" to "Izin Bluetooth belum aktif."))
            return
        }
        if (address.isEmpty() || payloadJson.isEmpty()) {
            result.success(mapOf("ok" to false, "error" to "Alamat Bluetooth atau data jadwal kosong."))
            return
        }
        val btMgr = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = btMgr?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.success(mapOf("ok" to false, "error" to "Bluetooth HP mati."))
            return
        }

        val serviceUuid = UUID.fromString("4D454E44-454B-0001-0000-000000000001")
        val infoUuid = UUID.fromString("4D454E44-454B-0002-0000-000000000001")
        val writeUuid = UUID.fromString("4D454E44-454B-0003-0000-000000000001")

        val device = try {
            adapter.getRemoteDevice(address)
        } catch (_: Exception) {
            result.success(mapOf("ok" to false, "error" to "Alamat Bluetooth tidak valid."))
            return
        }

        var finished = false
        fun finishOnce(payload: Map<String, Any>) {
            if (finished) return
            finished = true
            runOnUiThread { result.success(payload) }
        }

        val fullBytes = (payloadJson + "\n").toByteArray(Charsets.UTF_8)
        var boxDeviceId = ""
        var boxName = device.name ?: "MendekBox"
        var writeOffset = 0
        var chunkSize = 20
        var writeCharRef: BluetoothGattCharacteristic? = null

        val gattCb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    try {
                        gatt.requestMtu(256)
                    } catch (_: Exception) {
                        gatt.discoverServices()
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    try { gatt.close() } catch (_: Exception) {}
                    if (!finished) {
                        finishOnce(mapOf("ok" to false, "error" to "Koneksi Bluetooth ke Musik Box terputus."))
                    }
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS && mtu > 23) {
                    chunkSize = (mtu - 5).coerceIn(20, 200)
                }
                gatt.discoverServices()
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    gatt.disconnect()
                    finishOnce(mapOf("ok" to false, "error" to "Gagal membaca layanan Bluetooth Musik Box."))
                    return
                }
                val svc = gatt.getService(serviceUuid)
                val infoChar = svc?.getCharacteristic(infoUuid)
                val wChar = svc?.getCharacteristic(writeUuid)
                if (svc == null || infoChar == null || wChar == null) {
                    gatt.disconnect()
                    finishOnce(mapOf("ok" to false, "error" to "Perangkat ini bukan Smart Musik Box Mendek Arena."))
                    return
                }
                writeCharRef = wChar
                gatt.readCharacteristic(infoChar)
            }

            @Suppress("DEPRECATION")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (status == BluetoothGatt.GATT_SUCCESS && characteristic.uuid == infoUuid) {
                    try {
                        val txt = String(characteristic.value ?: ByteArray(0), Charsets.UTF_8)
                        val obj = JSONObject(txt)
                        boxDeviceId = obj.optString("box_device_id", "").trim()
                        val n = obj.optString("name", "").trim()
                        if (n.isNotEmpty()) boxName = n
                    } catch (_: Exception) {
                    }
                }
                if (boxDeviceId.isEmpty()) {
                    gatt.disconnect()
                    finishOnce(mapOf("ok" to false, "error" to "Musik Box tidak mengembalikan Chip ID."))
                    return
                }
                writeNextChunk(gatt)
            }

            @Suppress("DEPRECATION")
            private fun writeNextChunk(gatt: BluetoothGatt) {
                val wc = writeCharRef ?: return
                if (writeOffset >= fullBytes.size) {
                    gatt.disconnect()
                    finishOnce(mapOf("ok" to true, "boxDeviceId" to boxDeviceId, "boxName" to boxName))
                    return
                }
                val end = minOf(writeOffset + chunkSize, fullBytes.size)
                val slice = fullBytes.copyOfRange(writeOffset, end)
                writeOffset = end
                wc.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                wc.value = slice
                if (!gatt.writeCharacteristic(wc)) {
                    gatt.disconnect()
                    finishOnce(mapOf("ok" to false, "error" to "Gagal menulis data jadwal ke Musik Box."))
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    gatt.disconnect()
                    finishOnce(mapOf("ok" to false, "error" to "Musik Box gagal menyimpan potongan data."))
                    return
                }
                writeNextChunk(gatt)
            }
        }

        val gatt = device.connectGatt(this, false, gattCb, BluetoothDevice.TRANSPORT_LE)
        Handler(Looper.getMainLooper()).postDelayed({
            if (!finished) {
                try { gatt?.disconnect(); gatt?.close() } catch (_: Exception) {}
                finishOnce(mapOf("ok" to false, "error" to "Waktu pairing Bluetooth habis (timeout 15 detik)."))
            }
        }, 15000)
    }

    private fun encryptFileToMbxInternal(
        srcPath: String,
        fileName: String,
        boxKey: String,
        boxDeviceId: String,
        result: MethodChannel.Result
    ) {
        if (srcPath.isEmpty() || boxKey.isEmpty() || boxDeviceId.isEmpty()) {
            result.success(mapOf("ok" to false, "error" to "Data enkripsi belum lengkap."))
            return
        }
        ioExecutor.execute {
            try {
                val srcFile = File(srcPath)
                if (!srcFile.exists()) {
                    runOnUiThread {
                        result.success(mapOf("ok" to false, "error" to "File sumber tidak ditemukan."))
                    }
                    return@execute
                }
                val plainBytes = FileInputStream(srcFile).use { it.readBytes() }
                val nonce = ByteArray(16)
                SecureRandom().nextBytes(nonce)

                val seedStr = "${boxKey.trim().uppercase(Locale.ROOT)}:${boxDeviceId.trim().uppercase(Locale.ROOT)}:MENDEK_MBX_V1"
                val md = MessageDigest.getInstance("SHA-256")
                val masterSecret = md.digest(seedStr.toByteArray(Charsets.UTF_8))

                val outBytes = ByteArray(24 + plainBytes.size)
                outBytes[0] = 'M'.code.toByte()
                outBytes[1] = 'B'.code.toByte()
                outBytes[2] = 'X'.code.toByte()
                outBytes[3] = '1'.code.toByte()
                System.arraycopy(nonce, 0, outBytes, 4, 16)
                val lenBuf = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(plainBytes.size).array()
                System.arraycopy(lenBuf, 0, outBytes, 20, 4)

                val seedBlock = ByteArray(52)
                System.arraycopy(masterSecret, 0, seedBlock, 0, 32)
                System.arraycopy(nonce, 0, seedBlock, 32, 16)
                val totalBlocks = (plainBytes.size + 31) / 32
                for (counter in 0 until totalBlocks) {
                    seedBlock[48] = (counter and 0xFF).toByte()
                    seedBlock[49] = ((counter shr 8) and 0xFF).toByte()
                    seedBlock[50] = ((counter shr 16) and 0xFF).toByte()
                    seedBlock[51] = ((counter shr 24) and 0xFF).toByte()
                    md.reset()
                    val keyBlock = md.digest(seedBlock)
                    val base = counter * 32
                    val limit = minOf(32, plainBytes.size - base)
                    for (j in 0 until limit) {
                        outBytes[24 + base + j] = (plainBytes[base + j].toInt() xor keyBlock[j].toInt()).toByte()
                    }
                }

                val safeName = if (fileName.lowercase(Locale.ROOT).endsWith(".mbx")) fileName else "$fileName.mbx"
                val outDir = File(
                    getExternalFilesDir(Environment.DIRECTORY_MUSIC) ?: filesDir,
                    "mbx_locked"
                )
                if (!outDir.exists()) outDir.mkdirs()
                val outFile = File(outDir, safeName)
                FileOutputStream(outFile).use { it.write(outBytes) }

                runOnUiThread {
                    result.success(
                        mapOf(
                            "ok" to true,
                            "outputPath" to outFile.absolutePath,
                            "fileName" to safeName,
                            "sizeBytes" to outBytes.size
                        )
                    )
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.success(mapOf("ok" to false, "error" to (e.message ?: "Gagal mengunci file audio.")))
                }
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
