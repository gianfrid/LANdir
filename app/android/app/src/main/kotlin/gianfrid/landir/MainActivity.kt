package gianfrid.landir

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val mediaStoreChannel = "landir/media_store"
    private val hotspotChannel = "landir/hotspot"
    private val shareIntentsChannel = "landir/share_intent"
    private val shareIntentsEventsChannel = "landir/share_intent/events"

    companion object {
        // Cache folder holding copies of shared files, pruned in
        // [configureFlutterEngine].
        private const val SHARED_CACHE_DIR = "shared"
        private const val SHARED_CACHE_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
    }

    // Share payload (JSON, see lib/src/platform/share_intent.dart) of the
    // intent that launched a cold-started app, handed to Dart once.
    private var initialSharePayload: String? = null
    private var shareEventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Capture the launching share before anything else: a cold start
        // triggered by a share (singleTop) never produces an onNewIntent.
        initialSharePayload = extractSharePayload(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // App already running: hand the shares straight to Dart.
        extractSharePayload(intent)?.let { shareEventSink?.success(it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareIntentsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Returns the payload of the launching share exactly
                    // once; a cleared state must not re-upload on restarts.
                    "getInitialShares" -> {
                        val payload = initialSharePayload
                        initialSharePayload = null
                        result.success(payload)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, shareIntentsEventsChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    shareEventSink = events
                }

                override fun onCancel(args: Any?) {
                    shareEventSink = null
                }
            })

        pruneSharedCache()

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

    // ---------------------------------------------------------------
    // Share-sheet intake (SEND / SEND_MULTIPLE, see AndroidManifest.xml).
    //
    // Every MIME type is accepted: photos, text, zip, anything the system
    // share sheet offers. Each EXTRA_STREAM Uri is copied into the app
    // cache through ContentResolver — the share grant permits reading
    // exactly that Uri regardless of its content type, while the raw
    // /storage path behind a document or file:// Uri is not readable under
    // scoped storage. Copying up front is what makes non-media files
    // (zips, PDFs, ...) uploadable, not just media.
    // ---------------------------------------------------------------

    // JSON payload of the shares carried by [intent], or null when it is
    // not a share intent (launcher, hotspot, ...). Per item: {"path",
    // "filename"} for files, {"text"} for plain-text shares.
    private fun extractSharePayload(intent: Intent?): String? {
        if (intent == null) return null
        val items = mutableListOf<JSONObject>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val stream = IntentCompat.getParcelableExtra(
                    intent, Intent.EXTRA_STREAM, Uri::class.java)
                if (stream != null) {
                    toShareJson(stream)?.let { items.add(it) }
                } else {
                    intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }?.let { text ->
                        items.add(JSONObject().put("text", text))
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = IntentCompat.getParcelableArrayListExtra(
                    intent, Intent.EXTRA_STREAM, Uri::class.java)
                streams?.forEach { uri -> toShareJson(uri)?.let { items.add(it) } }
            }
            else -> return null
        }
        if (items.isEmpty()) return null
        return JSONArray(items).toString()
    }

    // Copy [uri] into the cache and describe the result as a share item.
    // Returns null when the content cannot be read; the caller skips it
    // and reports the failure in its own summary.
    private fun toShareJson(uri: Uri): JSONObject? {
        val resolver = applicationContext.contentResolver
        val mime = try { resolver.getType(uri) } catch (e: Exception) { null }
        val name = shareFileName(uri, mime)
        val path = copyShareToCache(uri, name) ?: return null
        return JSONObject().put("path", path).put("filename", name)
    }

    // Best-effort upload file name: the provider's display name, then the
    // last path segment, then a generic name. A missing extension is
    // completed from the MIME type so "shared octet-stream" downloads
    // keep a usable name.
    private fun shareFileName(uri: Uri, mime: String?): String {
        var displayName: String? = null
        try {
            contentResolver
                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) displayName = cursor.getString(0)
                }
        } catch (e: Exception) { /* fall through to the next source */ }
        val base = displayName?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment?.let { Uri.decode(it) }?.takeIf { it.isNotBlank() }
            ?: "shared-file"
        var name = base.replace(Regex("[/\\\\\u0000]"), "_")
        if (!name.contains('.') && mime != null) {
            val ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            if (ext != null) name = "$name.$ext"
        }
        return name
    }

    // Materialize [uri] as a readable file. file:// targets that are
    // directly readable pass through un-copied; everything else (content://)
    // is copied so the share grant carries the actual bytes.
    private fun copyShareToCache(uri: Uri, name: String): String? {
        if ("file".equals(uri.scheme, ignoreCase = true) && uri.path != null) {
            val direct = File(uri.path!!)
            if (direct.canRead()) return direct.path
        }
        return try {
            val dir = File(cacheDir, SHARED_CACHE_DIR)
            dir.mkdirs()
            val target = File(dir, "${System.currentTimeMillis()}_$name")
            applicationContext.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(target).use { input.copyTo(it) }
            } ?: return null
            target.path
        } catch (e: Exception) {
            null
        }
    }

    // Delete copies of previously shared files that no pending upload can
    // still reference.
    private fun pruneSharedCache() {
        val dir = File(cacheDir, SHARED_CACHE_DIR)
        if (!dir.isDirectory) return
        val cutoff = System.currentTimeMillis() - SHARED_CACHE_MAX_AGE_MS
        dir.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
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
