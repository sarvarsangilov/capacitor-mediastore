package com.sangulov.plugins.mediastore

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
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
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

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
 * Все тяжёлые методы запускаются в [Dispatchers.IO], чтобы не блокировать
 * bridge-поток Capacitor и не вызывать ANR на больших галереях.
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

    override fun load() {
        super.load()
        mediaGallery = MediaGallery(context)
        filePicker = FilePicker(context)
    }

    override fun handleOnDestroy() {
        scope.cancel()
        super.handleOnDestroy()
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

        scope.launch {
            try {
                call.resolve(mediaGallery.getMedia(albumId, limit, offset, type))
            } catch (e: Exception) {
                call.reject("Failed to get media: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun getThumbnail(call: PluginCall) {
        val id = call.getString("id")
        if (id == null) {
            call.reject("Must provide id")
            return
        }
        val returnBase64 = call.getBoolean("returnBase64", false) ?: false
        val size = call.getInt("size", 256) ?: 256

        scope.launch {
            try {
                call.resolve(mediaGallery.getThumbnail(id, returnBase64, size))
            } catch (e: Exception) {
                call.reject("Failed to get thumbnail: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun getThumbnails(call: PluginCall) {
        val idsArr = call.getArray("ids")
        if (idsArr == null) {
            call.reject("Must provide ids")
            return
        }
        val ids = try {
            (0 until idsArr.length()).mapNotNull { idsArr.getString(it) }
        } catch (e: Exception) {
            call.reject("Invalid ids array", e)
            return
        }
        val size = call.getInt("size", 256) ?: 256

        scope.launch {
            try {
                call.resolve(mediaGallery.getThumbnails(ids, size))
            } catch (e: Exception) {
                call.reject("Failed to get thumbnails: ${e.message}", e)
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // File picker / Recent files
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Открывает системный пикер. Когда пользователь возвращается, отрабатывает
     * [handlePickFilesResult] — берёт persistable permission, сохраняет записи.
     */
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
            // отмена пользователем — отдаём пустой массив, не реджектим.
            val empty = JSObject().apply { put("files", JSArray()) }
            call.resolve(empty)
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
            call.reject("Must provide id")
            return
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
    fun removeRecentFile(call: PluginCall) {
        val id = call.getString("id")
        if (id.isNullOrEmpty()) {
            call.reject("Must provide id")
            return
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
