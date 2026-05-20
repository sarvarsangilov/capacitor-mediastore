package com.sangulov.plugins.mediastore

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.activity.result.ActivityResult
import androidx.core.content.ContextCompat
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.ActivityCallback
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.Collections

/**
 * CapacitorMediastorePlugin — Capacitor 8.x plugin для Android.
 *
 * Обработка разрешений на медиа:
 *  - Android 14+ (API 34): READ_MEDIA_IMAGES, READ_MEDIA_VIDEO,
 *                          READ_MEDIA_AUDIO, READ_MEDIA_VISUAL_USER_SELECTED
 *  - Android 13  (API 33): READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_AUDIO
 *  - Android 10–12 (API 29–32): READ_EXTERNAL_STORAGE (покрывает все типы)
 *
 * Файлпикер (`pickFiles`) **никаких** runtime-разрешений не требует —
 * `ACTION_OPEN_DOCUMENT` использует системный UI, который сам отдаёт URI
 * с пожизненным правом чтения через `takePersistableUriPermission`.
 *
 * Изменения в системной галерее (новые фото, удалённые видео и т.д.)
 * автоматически отдаются в JS через событие `mediaLibraryChanged` —
 * см. [ContentObserver] ниже.
 */
@CapacitorPlugin(
    name = "CapacitorMediastore",
    permissions = [
        Permission(
            strings = [Manifest.permission.READ_MEDIA_IMAGES],
            alias = "photos"
        ),
        Permission(
            strings = [Manifest.permission.READ_MEDIA_VIDEO],
            alias = "videos"
        ),
        Permission(
            strings = [Manifest.permission.READ_MEDIA_AUDIO],
            alias = "audio"
        ),
        Permission(
            strings = [Manifest.permission.READ_EXTERNAL_STORAGE],
            alias = "storage"
        )
    ]
)
class CapacitorMediastorePlugin : Plugin() {

    private lateinit var mediaGallery: MediaGallery
    private lateinit var filePicker: FilePicker
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Список pending-задач генерации миниатюр. При [cancelPendingThumbnails]
     * все они кооперативно отменяются.
     */
    private val thumbnailJobs = Collections.synchronizedList(mutableListOf<Job>())

    // ContentObserver state
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingChangeTypes = HashSet<String>()
    private val pendingChangeLock = Object()
    private val emitChangesRunnable = Runnable { flushPendingChanges() }
    private val mediaObservers = mutableListOf<Pair<Uri, ContentObserver>>()

    override fun load() {
        super.load()
        mediaGallery = MediaGallery(context)
        filePicker = FilePicker(context)
        registerMediaObservers()
    }

    override fun handleOnDestroy() {
        unregisterMediaObservers()
        thumbnailJobs.forEach { it.cancel() }
        thumbnailJobs.clear()
        scope.cancel()
        super.handleOnDestroy()
    }

    private fun trackThumbnailJob(job: Job) {
        thumbnailJobs.add(job)
        job.invokeOnCompletion { thumbnailJobs.remove(job) }
    }

    // ────────────────────────────────────────────────────────────────────────
    // ContentObserver — отдаёт mediaLibraryChanged в JS с дебаунсом 500ms
    // ────────────────────────────────────────────────────────────────────────

    private fun registerMediaObservers() {
        val uris = listOf(
            android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "photo",
            android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI to "video",
            android.provider.MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to "audio"
        )
        for ((uri, type) in uris) {
            val observer = object : ContentObserver(mainHandler) {
                override fun onChange(selfChange: Boolean) {
                    onChange(selfChange, null)
                }
                override fun onChange(selfChange: Boolean, changedUri: Uri?) {
                    scheduleChangeEmit(type)
                }
            }
            try {
                context.contentResolver.registerContentObserver(uri, true, observer)
                mediaObservers.add(uri to observer)
            } catch (_: Exception) { /* недоступная коллекция — игнор */ }
        }
    }

    private fun unregisterMediaObservers() {
        for ((_, observer) in mediaObservers) {
            try { context.contentResolver.unregisterContentObserver(observer) } catch (_: Exception) { }
        }
        mediaObservers.clear()
        mainHandler.removeCallbacks(emitChangesRunnable)
    }

    private fun scheduleChangeEmit(type: String) {
        synchronized(pendingChangeLock) {
            pendingChangeTypes.add(type)
        }
        mainHandler.removeCallbacks(emitChangesRunnable)
        mainHandler.postDelayed(emitChangesRunnable, 500)
    }

    private fun flushPendingChanges() {
        val types: List<String>
        synchronized(pendingChangeLock) {
            if (pendingChangeTypes.isEmpty()) return
            types = pendingChangeTypes.toList()
            pendingChangeTypes.clear()
        }
        val arr = JSArray()
        for (t in types) arr.put(t)
        val data = JSObject().apply { put("types", arr) }
        notifyListeners("mediaLibraryChanged", data)
    }

    // ────────────────────────────────────────────────────────────────────────
    // Permissions
    // ────────────────────────────────────────────────────────────────────────

    @PluginMethod
    override fun checkPermissions(call: PluginCall) {
        try {
            call.resolve(buildPermissionResult())
        } catch (e: Exception) {
            call.reject("Failed to check permissions", e)
        }
    }

    @PluginMethod
    override fun requestPermissions(call: PluginCall) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                requestPermissionForAliases(
                    arrayOf("photos", "videos", "audio"),
                    call,
                    "handlePermissionResult"
                )
            } else {
                requestPermissionForAliases(
                    arrayOf("storage"),
                    call,
                    "handlePermissionResult"
                )
            }
        } catch (e: Exception) {
            call.reject("Failed to request permissions", e)
        }
    }

    @PermissionCallback
    private fun handlePermissionResult(call: PluginCall) {
        call.resolve(buildPermissionResult())
    }

    private fun buildPermissionResult(): JSObject {
        val result = JSObject()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val fullPhotos = isPermissionGranted(Manifest.permission.READ_MEDIA_IMAGES)
            val fullVideos = isPermissionGranted(Manifest.permission.READ_MEDIA_VIDEO)
            val userSelected = isPermissionGranted("android.permission.READ_MEDIA_VISUAL_USER_SELECTED")

            result.put("photos", when {
                fullPhotos -> "granted"
                userSelected -> "limited"
                else -> "denied"
            })
            result.put("videos", when {
                fullVideos -> "granted"
                userSelected -> "limited"
                else -> "denied"
            })
            result.put("audio", permissionStatusString(Manifest.permission.READ_MEDIA_AUDIO))

        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            result.put("photos", permissionStatusString(Manifest.permission.READ_MEDIA_IMAGES))
            result.put("videos", permissionStatusString(Manifest.permission.READ_MEDIA_VIDEO))
            result.put("audio", permissionStatusString(Manifest.permission.READ_MEDIA_AUDIO))

        } else {
            val status = permissionStatusString(Manifest.permission.READ_EXTERNAL_STORAGE)
            result.put("photos", status)
            result.put("videos", status)
            result.put("audio", status)
        }

        return result
    }

    private fun isPermissionGranted(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun permissionStatusString(permission: String): String {
        return when {
            isPermissionGranted(permission) -> "granted"
            activity.shouldShowRequestPermissionRationale(permission) -> "prompt-with-rationale"
            else -> "prompt"
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Albums
    // ────────────────────────────────────────────────────────────────────────

    @PluginMethod
    fun getAlbums(call: PluginCall) {
        scope.launch {
            try {
                call.resolve(mediaGallery.getAlbums())
            } catch (e: Exception) {
                call.reject("Failed to get albums: ${e.message}", e)
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Media
    // ────────────────────────────────────────────────────────────────────────

    @PluginMethod
    fun getMedia(call: PluginCall) {
        val albumId = call.getString("albumId")
        val limit = call.getInt("limit", 20) ?: 20
        val offset = call.getInt("offset", 0) ?: 0
        val type = call.getString("type", "all") ?: "all"
        val cursor = call.getString("cursor")

        scope.launch {
            try {
                call.resolve(mediaGallery.getMedia(albumId, limit, offset, type, cursor))
            } catch (e: Exception) {
                call.reject("Failed to get media: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun hasMedia(call: PluginCall) {
        val type = call.getString("type", "all") ?: "all"
        scope.launch {
            try {
                val available = mediaGallery.hasMedia(type)
                call.resolve(JSObject().apply { put("available", available) })
            } catch (e: Exception) {
                call.reject("Failed to check media availability: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun resolveMediaPath(call: PluginCall) {
        val id = call.getString("id")
        if (id.isNullOrEmpty()) {
            call.reject("Must provide id"); return
        }
        scope.launch {
            try {
                call.resolve(mediaGallery.resolveMediaPath(id))
            } catch (e: Exception) {
                call.reject("Failed to resolve media path: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun getThumbnail(call: PluginCall) {
        val id = call.getString("id")
        if (id == null) {
            call.reject("Must provide id"); return
        }
        val returnBase64 = call.getBoolean("returnBase64", false) ?: false
        val size = call.getInt("size", 256) ?: 256
        val density = call.getDouble("density", 1.0) ?: 1.0

        val job = scope.launch {
            try {
                call.resolve(mediaGallery.getThumbnail(id, returnBase64, size, density))
            } catch (e: kotlinx.coroutines.CancellationException) {
                call.resolve(JSObject().apply {
                    put("webPath", "")
                    put("base64String", "")
                })
            } catch (e: Exception) {
                call.reject("Failed to get thumbnail: ${e.message}", e)
            }
        }
        trackThumbnailJob(job)
    }

    @PluginMethod
    fun getThumbnails(call: PluginCall) {
        val idsArr = call.getArray("ids")
        if (idsArr == null) {
            call.reject("Must provide ids"); return
        }
        val ids = try {
            (0 until idsArr.length()).mapNotNull { idsArr.getString(it) }
        } catch (e: Exception) {
            call.reject("Invalid ids array", e); return
        }
        val size = call.getInt("size", 256) ?: 256
        val density = call.getDouble("density", 1.0) ?: 1.0

        val job = scope.launch {
            try {
                call.resolve(mediaGallery.getThumbnails(ids, size, density))
            } catch (e: kotlinx.coroutines.CancellationException) {
                call.resolve(JSObject().apply { put("thumbnails", JSObject()) })
            } catch (e: Exception) {
                call.reject("Failed to get thumbnails: ${e.message}", e)
            }
        }
        trackThumbnailJob(job)
    }

    @PluginMethod
    fun prefetchThumbnails(call: PluginCall) {
        val idsArr = call.getArray("ids")
        if (idsArr == null) {
            call.reject("Must provide ids"); return
        }
        val ids = try {
            (0 until idsArr.length()).mapNotNull { idsArr.getString(it) }
        } catch (_: Exception) { emptyList() }
        val size = call.getInt("size", 256) ?: 256
        val density = call.getDouble("density", 1.0) ?: 1.0

        val job = scope.launch {
            try {
                mediaGallery.prefetchThumbnails(ids, size, density)
            } catch (_: kotlinx.coroutines.CancellationException) {
                // ok, отмена через cancelPendingThumbnails
            } catch (_: Exception) { /* swallow — это fire-and-forget */ }
        }
        trackThumbnailJob(job)
        // Резолвимся сразу — не ждём фактической генерации.
        call.resolve()
    }

    @PluginMethod
    fun cancelPendingThumbnails(call: PluginCall) {
        synchronized(thumbnailJobs) {
            thumbnailJobs.toList().forEach { it.cancel() }
            thumbnailJobs.clear()
        }
        call.resolve()
    }

    // ────────────────────────────────────────────────────────────────────────
    // File picker / Recent files
    // ────────────────────────────────────────────────────────────────────────

    @PluginMethod
    fun pickFiles(call: PluginCall) {
        val mimesArr = call.getArray("mimeTypes")
        val multiple = call.getBoolean("multiple", false) ?: false
        val mimes = try {
            if (mimesArr == null) emptyList()
            else (0 until mimesArr.length()).mapNotNull { mimesArr.getString(it) }
        } catch (_: Exception) { emptyList() }

        try {
            val intent = filePicker.buildPickIntent(mimes, multiple)
            startActivityForResult(call, intent, "handlePickFilesResult")
        } catch (e: Exception) {
            call.reject("Failed to open file picker: ${e.message}", e)
        }
    }

    @ActivityCallback
    private fun handlePickFilesResult(call: PluginCall, result: ActivityResult) {
        if (result.resultCode != Activity.RESULT_OK) {
            call.resolve(JSObject().apply { put("files", JSArray()) })
            return
        }
        val uris = filePicker.extractUris(result.data)
        scope.launch {
            try {
                val persisted = filePicker.persist(uris)
                val arr = JSArray()
                for (item in persisted) arr.put(item)
                call.resolve(JSObject().apply { put("files", arr) })
            } catch (e: Exception) {
                call.reject("Failed to persist picked files: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun getRecentFiles(call: PluginCall) {
        val limit = call.getInt("limit", 50) ?: 50
        val offset = call.getInt("offset", 0) ?: 0
        val mimesArr = call.getArray("mimeTypes")
        val mimes = try {
            if (mimesArr == null) emptyList()
            else (0 until mimesArr.length()).mapNotNull { mimesArr.getString(it) }
        } catch (_: Exception) { emptyList() }

        scope.launch {
            try {
                call.resolve(filePicker.list(limit, offset, mimes))
            } catch (e: Exception) {
                call.reject("Failed to list recent files: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun resolveRecentFile(call: PluginCall) {
        val id = call.getString("id")
        if (id.isNullOrEmpty()) {
            call.reject("Must provide id"); return
        }
        scope.launch {
            try {
                val obj = filePicker.resolve(id)
                val result = JSObject()
                if (obj != null) result.put("file", obj) else result.put("file", null as Any?)
                call.resolve(result)
            } catch (e: Exception) {
                call.reject("Failed to resolve recent file: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun readFileChunk(call: PluginCall) {
        val id = call.getString("id")
        if (id.isNullOrEmpty()) {
            call.reject("Must provide id"); return
        }
        val offset = (call.getLong("offset") ?: 0L).coerceAtLeast(0L)
        val length = call.getInt("length") ?: 0

        scope.launch {
            try {
                call.resolve(filePicker.readFileChunk(id, offset, length))
            } catch (e: Exception) {
                call.reject("Failed to read file chunk: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun removeRecentFile(call: PluginCall) {
        val id = call.getString("id")
        if (id.isNullOrEmpty()) {
            call.reject("Must provide id"); return
        }
        scope.launch {
            try {
                filePicker.remove(id)
                call.resolve()
            } catch (e: Exception) {
                call.reject("Failed to remove recent file: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun clearRecentFiles(call: PluginCall) {
        scope.launch {
            try {
                filePicker.clear()
                call.resolve()
            } catch (e: Exception) {
                call.reject("Failed to clear recent files: ${e.message}", e)
            }
        }
    }
}
