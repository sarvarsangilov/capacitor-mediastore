package com.sangulov.plugins.mediastore

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback

/**
 * CapacitorMediastorePlugin — Capacitor 8.x plugin для доступа к медиагалерее.
 *
 * Обработка разрешений:
 *  - Android 14+ (API 34): READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_VISUAL_USER_SELECTED
 *  - Android 13  (API 33): READ_MEDIA_IMAGES, READ_MEDIA_VIDEO
 *  - Android 10–12 (API 29–32): READ_EXTERNAL_STORAGE
 */
@CapacitorPlugin(
    name = "CapacitorMediastore",
    permissions = [
        // Android 13+ (API 33)
        Permission(
            strings = [Manifest.permission.READ_MEDIA_IMAGES],
            alias = "photos"
        ),
        Permission(
            strings = [Manifest.permission.READ_MEDIA_VIDEO],
            alias = "videos"
        ),
        // Android < 13
        Permission(
            strings = [Manifest.permission.READ_EXTERNAL_STORAGE],
            alias = "storage"
        )
    ]
)
class CapacitorMediastorePlugin : Plugin() {

    private lateinit var mediaGallery: MediaGallery

    override fun load() {
        super.load()
        mediaGallery = MediaGallery(context)
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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // Android 14+ — запрашиваем READ_MEDIA_VISUAL_USER_SELECTED + READ_MEDIA_IMAGES + READ_MEDIA_VIDEO
                requestAllPermissions(call, "handlePermissionResult")
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // Android 13 — READ_MEDIA_IMAGES + READ_MEDIA_VIDEO
                requestPermissionForAliases(
                    arrayOf("photos", "videos"),
                    call,
                    "handlePermissionResult"
                )
            } else {
                // Android 10–12 — READ_EXTERNAL_STORAGE
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

    /**
     * Строит объект с текущим статусом разрешений, адаптированный под версию Android.
     */
    private fun buildPermissionResult(): JSObject {
        val result = JSObject()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+: проверяем READ_MEDIA_VISUAL_USER_SELECTED для "limited" доступа
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

        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13
            result.put("photos", permissionStatusString(Manifest.permission.READ_MEDIA_IMAGES))
            result.put("videos", permissionStatusString(Manifest.permission.READ_MEDIA_VIDEO))

        } else {
            // Android 10–12
            val status = permissionStatusString(Manifest.permission.READ_EXTERNAL_STORAGE)
            result.put("photos", status)
            result.put("videos", status)
        }

        return result
    }

    /**
     * Проверяет наличие конкретного разрешения.
     */
    private fun isPermissionGranted(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Возвращает строковый статус разрешения: "granted", "denied" или "prompt".
     */
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
        try {
            val result = mediaGallery.getAlbums()
            call.resolve(result)
        } catch (e: Exception) {
            call.reject("Failed to get albums: ${e.message}", e)
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Media
    // ────────────────────────────────────────────────────────────────────────

    @PluginMethod
    fun getMedia(call: PluginCall) {
        try {
            val albumId = call.getString("albumId")
            val limit = call.getInt("limit", 20) ?: 20
            val offset = call.getInt("offset", 0) ?: 0
            val type = call.getString("type", "all") ?: "all"

            val result = mediaGallery.getMedia(albumId, limit, offset, type)
            call.resolve(result)
        } catch (e: Exception) {
            call.reject("Failed to get media: ${e.message}", e)
        }
    }
}
