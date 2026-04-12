package com.puclnu.photorename

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.IntentSender
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "com.puclnu.photorename/media"
    private var pendingRename: PendingRename? = null
    private var pendingResult: MethodChannel.Result? = null

    private val REQUEST_WRITE_CONSENT = 1001
    private val REQUEST_PICK_TREE = 1002
    private var pendingPickTreeResult: MethodChannel.Result? = null

    private data class PendingRename(
        val uri: Uri,
        val newDisplayName: String,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "pickTree" -> {
                        handlePickTree(result)
                    }
                    "renameMedia" -> {
                        val path = call.argument<String>("path")
                        val newDisplayName = call.argument<String>("newName")
                        if (path.isNullOrEmpty() || newDisplayName.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "path/newName required", null)
                            return@setMethodCallHandler
                        }
                        handleRename(path, newDisplayName, result)
                    }
                    "safRename" -> {
                        val tree = call.argument<String>("treeUri")
                        val rel = call.argument<String>("relativePath")
                        val newName = call.argument<String>("newName")
                        if (tree.isNullOrEmpty() || rel.isNullOrEmpty() || newName.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "treeUri/relativePath/newName required", null)
                        } else {
                            try {
                                val ok = safRename(tree, rel, newName)
                                result.success(ok)
                            } catch (e: Exception) {
                                result.error("EXCEPTION", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handlePickTree(result: MethodChannel.Result) {
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
                putExtra("android.content.extra.SHOW_ADVANCED", true)
            }
            pendingPickTreeResult = result
            startActivityForResult(intent, REQUEST_PICK_TREE)
        } catch (e: Exception) {
            result.error("PICK_FAILED", e.message, null)
        }
    }

    private fun handleRename(path: String, newDisplayName: String, result: MethodChannel.Result) {
        try {
            val uri = findImageUri(path)
            if (uri == null) {
                result.error("NOT_FOUND", "Media not found for path", null)
                return
            }
            try {
                val updated = contentResolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, newDisplayName) },
                    null,
                    null
                )
                if (updated != null && updated > 0) {
                    result.success(true)
                } else {
                    result.error("UPDATE_FAILED", "MediaStore update returned 0 rows", null)
                }
            } catch (sec: SecurityException) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    try {
                        val pi = MediaStore.createWriteRequest(
                            contentResolver,
                            listOf(uri)
                        )
                        pendingRename = PendingRename(uri, newDisplayName)
                        pendingResult = result
                        startIntentSenderForResult(
                            pi.intentSender,
                            REQUEST_WRITE_CONSENT,
                            null,
                            0,
                            0,
                            0,
                            null
                        )
                    } catch (e: Exception) {
                        result.error("WRITE_REQUEST_FAILED", e.message, null)
                    }
                } else {
                    result.error("SECURITY_EXCEPTION", sec.message, null)
                }
            }
        } catch (e: Exception) {
            result.error("EXCEPTION", e.message, null)
        }
    }

    private fun safRename(treeUriStr: String, relativePath: String, newDisplayName: String): Boolean {
        val treeUri = Uri.parse(treeUriStr)
        val root = androidx.documentfile.provider.DocumentFile.fromTreeUri(this, treeUri)
            ?: return false
        val segments = relativePath.split('/')
        var current: androidx.documentfile.provider.DocumentFile? = root
        for (seg in segments) {
            if (seg.isEmpty()) continue
            val child = current?.findFile(seg)
            if (child == null) return false
            current = child
        }
        return current?.renameTo(newDisplayName) == true
    }

    private fun findImageUri(path: String): Uri? {
        val file = File(path)
        val name = file.name

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val storageRoot = Environment.getExternalStorageDirectory().absolutePath
            var rel = file.parent?.removePrefix(storageRoot)
            if (rel != null && rel.startsWith("/")) rel = rel.substring(1)
            if (rel != null && !rel.endsWith("/")) rel = "$rel/"

            val projection = arrayOf(MediaStore.Images.Media._ID)
            val selection = "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?"
            val selectionArgs = arrayOf(name, rel ?: "")
            queryOne(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, selection, selectionArgs)
        } else {
            val projection = arrayOf(MediaStore.Images.Media._ID)
            val selection = "${MediaStore.Images.Media.DATA}=?"
            val selectionArgs = arrayOf(path)
            queryOne(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, selection, selectionArgs)
        }
    }

    private fun queryOne(
        contentUri: Uri,
        projection: Array<String>,
        selection: String,
        selectionArgs: Array<String>
    ): Uri? {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(contentUri, projection, selection, selectionArgs, null)
            if (cursor != null && cursor.moveToFirst()) {
                val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val id = cursor.getLong(idIndex)
                ContentUris.withAppendedId(contentUri, id)
            } else null
        } finally {
            cursor?.close()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_WRITE_CONSENT) {
            val currentResult = pendingResult
            val pending = pendingRename
            pendingResult = null
            pendingRename = null
            if (currentResult == null || pending == null) return

            if (resultCode == Activity.RESULT_OK) {
                try {
                    val updated = contentResolver.update(
                        pending.uri,
                        ContentValues().apply {
                            put(MediaStore.MediaColumns.DISPLAY_NAME, pending.newDisplayName)
                        },
                        null,
                        null
                    )
                    if (updated != null && updated > 0) {
                        currentResult.success(true)
                    } else {
                        currentResult.error("UPDATE_FAILED", "MediaStore update returned 0 rows", null)
                    }
                } catch (e: Exception) {
                    currentResult.error("EXCEPTION", e.message, null)
                }
            } else {
                currentResult.error("USER_DENIED", "User denied write consent", null)
            }
        } else if (requestCode == REQUEST_PICK_TREE) {
            val res = pendingPickTreeResult
            pendingPickTreeResult = null
            if (res == null) return
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uri = data.data
                if (uri == null) {
                    res.error("NO_URI", "No uri returned", null)
                    return
                }
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) {}

                val docId = DocumentsContract.getTreeDocumentId(uri) // e.g., primary:DCIM/Camera
                var absPath: String? = null
                val parts = docId.split(":", limit = 2)
                if (parts.size == 2 && parts[0].equals("primary", ignoreCase = true)) {
                    val base = Environment.getExternalStorageDirectory().absolutePath
                    absPath = "$base/${parts[1]}"
                }
                val map = HashMap<String, Any>()
                map["treeUri"] = uri.toString()
                if (absPath != null) map["path"] = absPath
                res.success(map)
            } else {
                res.error("CANCELED", "User canceled", null)
            }
        }
    }
}
