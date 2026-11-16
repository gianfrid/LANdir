package com.example.landir_app

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val mediaStoreChannel = "landir/media_store"
    private val hotspotChannel = "landir/hotspot"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaStoreChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "writeFile" -> {
                        val name = call.argument<String>("name")!!
                        val bytes = call.argument<ByteArray>("bytes")!!
                        val overwrite = call.argument<Boolean>("overwrite") == true
                        try {
                            val uri = writeToDownloads(name, bytes, overwrite)
                            result.success(uri)
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", e.message, null)
                        }
                    }
                    "resolveFile" -> {
                        val name = call.argument<String>("name")!!
                        result.success(resolveInDownloads(name))
                    }
                    "listFiles" -> {
                        result.success(listDownloads())
                    }
                    "readFile" -> {
                        val name = call.argument<String>("name")!!
                        try {
                            result.success(readFromDownloads(name))
                        } catch (e: Exception) {
                            result.error("READ_FAILED", e.message, null)
                        }
                    }
                    "fileSize" -> {
                        val name = call.argument<String>("name")!!
                        result.success(sizeInDownloads(name))
                    }
                    "openFile" -> {
                        val name = call.argument<String>("name")!!
                        try {
                            openInDownloads(name)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    "fileExists" -> {
                        val name = call.argument<String>("name")!!
                        result.success(fileExistsInDownloads(name))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hotspotChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startLocalOnlyHotspot" -> startLocalOnlyHotspot(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun writeToDownloads(name: String, bytes: ByteArray, overwrite: Boolean): String {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        if (overwrite) {
            // Replace the existing row in place: inserting a duplicate
            // DISPLAY_NAME would make MediaStore auto-rename it.
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
            resolver.query(collection, projection, selection, arrayOf(name), null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val uri = android.content.ContentUris.withAppendedId(collection, cursor.getLong(0))
                    resolver.openOutputStream(uri, "w")!!.use { it.write(bytes) }
                    return uri.toString()
                }
            }
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mimeTypeFor(name))
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)!!
        resolver.openOutputStream(uri)!!.use { it.write(bytes) }
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri.toString()
    }

    private fun resolveInDownloads(name: String): String? {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        resolver.query(collection, projection, selection, arrayOf(name), null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(0)
                return "content://media/external_primary/downloads/$id"
            }
        }
        return null
    }

    private fun listDownloads(): List<Map<String, Any>> {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(
            MediaStore.Downloads.DISPLAY_NAME,
            MediaStore.Downloads.SIZE,
            MediaStore.Downloads.DATE_MODIFIED,
        )
        val result = mutableListOf<Map<String, Any>>()
        resolver.query(collection, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                result.add(mapOf(
                    "name" to (cursor.getString(0) ?: ""),
                    "size" to cursor.getLong(1),
                    "mtime" to (cursor.getLong(2) / 1000), // seconds
                ))
            }
        }
        return result
    }

    private fun sizeInDownloads(name: String): Int {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads.SIZE)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        resolver.query(collection, projection, selection, arrayOf(name), null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getLong(0).toInt()
        }
        return 0
    }

    private fun readFromDownloads(name: String): ByteArray? {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        var uri: android.net.Uri? = null
        resolver.query(collection, projection, selection, arrayOf(name), null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(0)
                uri = android.content.ContentUris.withAppendedId(collection, id)
            }
        }
        return uri?.let { resolver.openInputStream(it)?.use { it.readBytes() } }
    }

    private fun fileExistsInDownloads(name: String): Boolean {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        resolver.query(collection, projection, selection, arrayOf(name), null)?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    private fun openInDownloads(name: String) {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.MIME_TYPE)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        var uri: android.net.Uri? = null
        var mime: String? = null
        resolver.query(collection, projection, selection, arrayOf(name), null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                uri = android.content.ContentUris.withAppendedId(collection, cursor.getLong(0))
                mime = cursor.getString(1)
            }
        }
        uri ?: throw Exception("file not found in Downloads: $name")
        // The file extension wins over the stored MIME: ACTION_VIEW handlers
        // (e.g. the package installer for .apk) match on the intent type.
        val ext = name.substringAfterLast('.', "").lowercase()
        val extMime = android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(ext)
        val resolvedMime = extMime ?: mime ?: "application/octet-stream"
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
            setDataAndType(uri, resolvedMime)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            applicationContext.startActivity(intent)
        } catch (e: android.content.ActivityNotFoundException) {
            throw Exception("no app on this device can open $name")
        }
    }

    private fun mimeTypeFor(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    private fun startLocalOnlyHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(null)
            return
        }
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.NEARBY_WIFI_DEVICES)
            != PackageManager.PERMISSION_GRANTED) {
            // Caller handles fallback to manual hotspot
            result.success(null)
            return
        }
        wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation?) {
                val config = reservation?.softApConfiguration
                result.success(mapOf(
                    "ssid" to (config?.ssid ?: ""),
                    "gatewayIp" to "192.168.43.1",
                ))
            }
            override fun onStopped() {}
            override fun onFailed(reason: Int) {
                result.success(null)
            }
        }, null)
    }
}
