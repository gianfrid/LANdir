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
import android.provider.DocumentsContract
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
    private val safChannel = "landir/saf"
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
                        // Optional "path": relative dir to list ('' or absent
                        // = root). Returns the DIRECT children, with subfolders
                        // reported as {"is_dir": true} entries so clients can
                        // navigate the folder tree.
                        val path = call.argument<String>("path") ?: ""
                        result.success(listDownloads(path))
                    }
                    // Whether a relative dir exists: on API 29+ a folder
                    // "exists" when any Downloads row lives under its
                    // RELATIVE_PATH prefix (dirs have no row of their own).
                    "dirExists" -> {
                        val rel = call.argument<String>("name") ?: ""
                        result.success(dirExists(rel))
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, safChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Recursively list every file under a SAF tree URI as a
                    // JSON array of {"relativePath", "size"}.
                    "listTree" -> {
                        try {
                            val treeUri = Uri.parse(call.argument<String>("treeUri")!!)
                            result.success(listTree(treeUri))
                        } catch (e: Exception) {
                            result.error("LIST_FAILED", e.message, null)
                        }
                    }
                    // Read one file from the tree by its relative path.
                    "readTreeFile" -> {
                        try {
                            val treeUri = Uri.parse(call.argument<String>("treeUri")!!)
                            val rel = call.argument<String>("relativePath")!!
                            val bytes = readTreeFile(treeUri, rel)
                            if (bytes != null) result.success(bytes)
                            else result.error("READ_FAILED", "cannot read $rel", null)
                        } catch (e: Exception) {
                            result.error("READ_FAILED", e.message, null)
                        }
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

    // ---------------------------------------------------------------
    // SAF folder-tree traversal (host-view "Add folder").
    //
    // FilePicker.pickDirectory() hands back the tree content:// URI from
    // ACTION_OPEN_DOCUMENT_TREE; only DocumentsContract can walk it under
    // scoped storage. Files are reported with their path relative to the
    // picked root so the upload preserves the folder structure.
    // ---------------------------------------------------------------

    private fun listTree(treeUri: Uri): String {
        val out = JSONArray()
        walkTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri), "", out)
        return out.toString()
    }

    private fun walkTree(treeUri: Uri, parentDocId: String, prefix: String, out: JSONArray) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        try {
            contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0) ?: continue
                    val name = cursor.getString(1)?.takeIf { it.isNotBlank() } ?: continue
                    val mime = cursor.getString(2) ?: ""
                    val rel = if (prefix.isEmpty()) name else "$prefix/$name"
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        walkTree(treeUri, id, rel, out)
                    } else {
                        out.put(JSONObject()
                            .put("relativePath", rel)
                            .put("size", cursor.getLong(3)))
                    }
                }
            }
        } catch (e: Exception) {
            // Unreadable subtree (revoked grant, weird provider): skip it,
            // the Dart side reports only what it actually received.
        }
    }

    private fun readTreeFile(treeUri: Uri, relativePath: String): ByteArray? {
        val segments = relativePath.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) return null
        var docId = DocumentsContract.getTreeDocumentId(treeUri)
        for (i in 0 until segments.size - 1) {
            docId = findChildDocId(treeUri, docId, segments[i]) ?: return null
        }
        val fileDocId = findChildDocId(treeUri, docId, segments.last()) ?: return null
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, fileDocId)
        return try {
            contentResolver.openInputStream(docUri)?.use { it.readBytes() }
        } catch (e: Exception) {
            null
        }
    }

    private fun findChildDocId(treeUri: Uri, parentDocId: String, name: String): String? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        )
        val selection = "${DocumentsContract.Document.COLUMN_DISPLAY_NAME} = ?"
        try {
            contentResolver.query(childrenUri, projection, selection, arrayOf(name), null)?.use { cursor ->
                if (cursor.moveToFirst()) return cursor.getString(0)
            }
        } catch (e: Exception) { /* fall through */ }
        return null
    }

    // Split a relative path ("sub/photo.jpg") into the MediaStore pair
    // (RELATIVE_PATH, DISPLAY_NAME). RELATIVE_PATH exists only on API 29+;
    // below that the path is flattened into the display name with "__" so
    // DISPLAY_NAME stays a single valid segment.
    private fun mediaStorePathFor(name: String): Pair<String, String> {
        val idx = name.lastIndexOf('/')
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && idx > 0) {
            Pair("Download/" + name.substring(0, idx) + "/", name.substring(idx + 1))
        } else {
            Pair("Download/", name.replace("/", "__"))
        }
    }

    // WHERE clause + args matching one Downloads row by relative path.
    private fun selectionFor(name: String): Pair<String, Array<String>> {
        val (rel, display) = mediaStorePathFor(name)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Pair(
                "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?",
                arrayOf(display, rel))
        } else {
            Pair("${MediaStore.Downloads.DISPLAY_NAME} = ?", arrayOf(display))
        }
    }

    private fun writeToDownloads(name: String, bytes: ByteArray, overwrite: Boolean): String {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val (rel, display) = mediaStorePathFor(name)
        if (overwrite) {
            // Replace = delete the existing row(s), then fall through to the
            // insert below. Writing in place with openOutputStream(uri, "w")
            // is NOT reliable here: for media URIs "w" may not truncate
            // (documented ContentResolver behavior), so a shorter new file
            // would keep the old file's tail bytes -> corrupt file.
            val projection = arrayOf(MediaStore.Downloads._ID)
            val (selection, args) = selectionFor(name)
            resolver.query(collection, projection, selection, args, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val uri = android.content.ContentUris.withAppendedId(collection, cursor.getLong(0))
                    resolver.delete(uri, null, null)
                }
            }
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, display)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Downloads.RELATIVE_PATH, rel)
            }
            put(MediaStore.Downloads.MIME_TYPE, mimeTypeFor(display))
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
        val (selection, args) = selectionFor(name)
        resolver.query(collection, projection, selection, args, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(0)
                return "content://media/external_primary/downloads/$id"
            }
        }
        return null
    }

    // Direct children of the relative dir [rel] ('' = Downloads root):
    // files directly inside it plus one is_dir entry per subfolder (size 0,
    // mtime = newest file inside). Below API 29 subfolders don't exist
    // (paths are flattened into DISPLAY_NAME), so only the root lists.
    private fun listDownloads(rel: String): List<Map<String, Any>> {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = mutableListOf(
            MediaStore.Downloads.DISPLAY_NAME,
            MediaStore.Downloads.SIZE,
            MediaStore.Downloads.DATE_MODIFIED,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection.add(MediaStore.Downloads.RELATIVE_PATH)
        }
        val prefix = if (rel.isEmpty()) "" else "$rel/"
        val files = mutableListOf<Map<String, Any>>()
        val dirs = mutableMapOf<String, Long>() // dir name -> newest mtime inside
        resolver.query(collection, projection.toTypedArray(), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                var name = cursor.getString(0) ?: ""
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    // Recompose the full relative path so folder uploads
                    // keep their structure in the listing.
                    val rowRel = cursor.getString(3)?.removePrefix("Download/") ?: ""
                    if (rowRel.isNotEmpty()) name = "$rowRel$name"
                } else if (rel.isNotEmpty()) {
                    continue // pre-Q: no subdirs exist
                }
                if (rel.isNotEmpty() && !name.startsWith(prefix)) continue
                val rest = if (rel.isEmpty()) name else name.substring(prefix.length)
                if (rest.isEmpty()) continue
                val mtimeSec = cursor.getLong(2) / 1000
                val slash = rest.indexOf('/')
                if (slash >= 0) {
                    val dirName = rest.substring(0, slash)
                    dirs[dirName] = maxOf(dirs[dirName] ?: 0L, mtimeSec)
                } else {
                    files.add(mapOf(
                        "name" to rest,
                        "size" to cursor.getLong(1),
                        "mtime" to mtimeSec,
                        "is_dir" to false,
                    ))
                }
            }
        }
        for ((dirName, mtime) in dirs) {
            files.add(mapOf(
                "name" to dirName,
                "size" to 0L,
                "mtime" to mtime,
                "is_dir" to true,
            ))
        }
        return files
    }

    // A folder exists when any Downloads row lives under its RELATIVE_PATH
    // prefix ("Download/<rel>/..."); RELATIVE_PATH only exists on API 29+.
    private fun dirExists(rel: String): Boolean {
        if (rel.isEmpty()) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val prefix = "Download/$rel/"
        // Escape LIKE wildcards ('%', '_', '\') in the prefix, then match
        // everything below it.
        val pattern = prefix
            .replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_") + "%"
        val selection = "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? ESCAPE '\\'"
        resolver.query(collection, arrayOf(MediaStore.Downloads._ID), selection, arrayOf(pattern), null)?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    private fun sizeInDownloads(name: String): Int {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads.SIZE)
        val (selection, args) = selectionFor(name)
        resolver.query(collection, projection, selection, args, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getLong(0).toInt()
        }
        return 0
    }

    private fun readFromDownloads(name: String): ByteArray? {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads._ID)
        val (selection, args) = selectionFor(name)
        var uri: android.net.Uri? = null
        resolver.query(collection, projection, selection, args, null)?.use { cursor ->
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
        val (selection, args) = selectionFor(name)
        resolver.query(collection, projection, selection, args, null)?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    private fun openInDownloads(name: String) {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.MIME_TYPE)
        val (selection, args) = selectionFor(name)
        var uri: android.net.Uri? = null
        var mime: String? = null
        resolver.query(collection, projection, selection, args, null)?.use { cursor ->
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
