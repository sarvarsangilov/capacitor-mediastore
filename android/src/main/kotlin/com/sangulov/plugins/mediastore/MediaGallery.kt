package com.sangulov.plugins.mediastore

import android.content.ContentResolver
import android.content.ContentUris
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * MediaGallery — бизнес-логика доступа к медиагалерее устройства.
 *
 * Использует ContentResolver + MediaStore API для получения альбомов и медиафайлов.
 * Спроектирован с учётом производительности (Projection, LIMIT/OFFSET).
 */
class MediaGallery(private val contentResolver: ContentResolver) {

    companion object {
        private val isoFormat: SimpleDateFormat
            get() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Albums
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Возвращает список альбомов (bucket) с подсчётом файлов и обложкой.
     */
    fun getAlbums(): JSObject {
        val albums = mutableMapOf<String, AlbumInfo>()

        // Собираем данные из Images
        queryAlbumsFrom(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            albums,
            isVideo = false
        )
        // Собираем данные из Videos
        queryAlbumsFrom(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            albums,
            isVideo = true
        )

        val result = JSObject()
        val arr = JSArray()
        for ((_, info) in albums) {
            val obj = JSObject()
            obj.put("id", info.id)
            obj.put("title", info.title)
            obj.put("count", info.count)
            obj.put("coverUri", info.coverUri)
            arr.put(obj)
        }
        result.put("albums", arr)
        return result
    }

    private fun queryAlbumsFrom(
        collection: Uri,
        albums: MutableMap<String, AlbumInfo>,
        isVideo: Boolean
    ) {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_ADDED
        )

        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"

        contentResolver.query(collection, projection, null, null, sortOrder)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val bucketIdCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
            val bucketNameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)

            while (cursor.moveToNext()) {
                val bucketId = cursor.getString(bucketIdCol) ?: "unknown"
                val bucketName = cursor.getString(bucketNameCol) ?: "Unknown"
                val mediaId = cursor.getLong(idCol)

                val info = albums.getOrPut(bucketId) {
                    // Для обложки берём URI первого (самого свежего) файла
                    val coverUri = ContentUris.withAppendedId(collection, mediaId).toString()
                    AlbumInfo(
                        id = bucketId,
                        title = bucketName,
                        count = 0,
                        coverUri = coverUri
                    )
                }
                info.count++
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Media
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Возвращает список медиафайлов с метаданными, пагинацией и фильтрацией.
     *
     * @param albumId  ID альбома (bucket_id). null — все файлы.
     * @param limit    Максимальное количество элементов.
     * @param offset   Сдвиг.
     * @param type     "photo", "video" или "all".
     */
    fun getMedia(albumId: String?, limit: Int, offset: Int, type: String): JSObject {
        val collections = when (type) {
            "photo" -> listOf(CollectionInfo(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "photo"))
            "video" -> listOf(CollectionInfo(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video"))
            else -> listOf(
                CollectionInfo(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "photo"),
                CollectionInfo(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video")
            )
        }

        // Если тип "all" — собираем из обоих источников, сортируем по дате и пагинируем.
        val allItems = mutableListOf<JSObject>()
        var totalCount = 0

        for (col in collections) {
            totalCount += countMedia(col.uri, albumId)
            queryMedia(col.uri, col.type, albumId, allItems)
        }

        // Сортируем по дате DESC
        allItems.sortByDescending { it.optString("createdAt", "") }

        // Пагинация
        val end = minOf(offset + limit, allItems.size)
        val page = if (offset < allItems.size) allItems.subList(offset, end) else emptyList()

        val result = JSObject()
        val arr = JSArray()
        for (item in page) arr.put(item)
        result.put("media", arr)
        result.put("total", totalCount)
        result.put("hasMore", offset + limit < totalCount)
        return result
    }

    /**
     * Подсчитывает медиафайлы в коллекции с фильтром по альбому.
     */
    private fun countMedia(collection: Uri, albumId: String?): Int {
        val selection = albumId?.let { "${MediaStore.MediaColumns.BUCKET_ID} = ?" }
        val selectionArgs = albumId?.let { arrayOf(it) }

        val projection = arrayOf(MediaStore.MediaColumns._ID)

        contentResolver.query(collection, projection, selection, selectionArgs, null)?.use { cursor ->
            return cursor.count
        }
        return 0
    }

    /**
     * Выбирает все медиафайлы из коллекции (без LIMIT — пагинация в памяти для
     * корректной работы при type="all" с двумя источниками).
     */
    private fun queryMedia(
        collection: Uri,
        mediaType: String,
        albumId: String?,
        outList: MutableList<JSObject>
    ) {
        val projection = buildMediaProjection(mediaType)

        val selection = albumId?.let { "${MediaStore.MediaColumns.BUCKET_ID} = ?" }
        val selectionArgs = albumId?.let { arrayOf(it) }
        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"

        contentResolver.query(collection, projection, selection, selectionArgs, sortOrder)?.use { cursor ->
            while (cursor.moveToNext()) {
                outList.add(cursorToMediaItem(cursor, collection, mediaType))
            }
        }
    }

    /**
     * Строит массив колонок Projection для запроса медиафайлов.
     */
    private fun buildMediaProjection(mediaType: String): Array<String> {
        val base = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.BUCKET_ID
        )
        if (mediaType == "video") {
            base.add(MediaStore.Video.VideoColumns.DURATION)
        }
        return base.toTypedArray()
    }

    /**
     * Преобразует текущую строку курсора в JSObject-представление MediaItem.
     */
    private fun cursorToMediaItem(cursor: Cursor, collection: Uri, mediaType: String): JSObject {
        val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
        val displayName = cursor.getStringOrNull(MediaStore.MediaColumns.DISPLAY_NAME) ?: ""
        val mimeType = cursor.getStringOrNull(MediaStore.MediaColumns.MIME_TYPE) ?: ""
        val size = cursor.getLongOrZero(MediaStore.MediaColumns.SIZE)
        val width = cursor.getIntOrZero(MediaStore.MediaColumns.WIDTH)
        val height = cursor.getIntOrZero(MediaStore.MediaColumns.HEIGHT)
        val dateAdded = cursor.getLongOrZero(MediaStore.MediaColumns.DATE_ADDED)

        val duration = if (mediaType == "video") {
            val durationCol = cursor.getColumnIndex(MediaStore.Video.VideoColumns.DURATION)
            if (durationCol >= 0) cursor.getLong(durationCol) / 1000.0 else 0.0
        } else {
            0.0
        }

        val contentUri = ContentUris.withAppendedId(collection, id).toString()
        val thumbnailUri = contentUri // На Android 10+ content URI работает как thumbnail source

        val createdAt = isoFormat.format(Date(dateAdded * 1000))

        return JSObject().apply {
            put("id", id.toString())
            put("type", mediaType)
            put("uri", contentUri)
            put("thumbnailUri", thumbnailUri)
            put("width", width)
            put("height", height)
            put("createdAt", createdAt)
            put("duration", duration)
            put("mimeType", mimeType)
            put("fileSize", size)
            put("fileName", displayName)
        }
    }

    // ── Helper extension functions ────────────────────────────────────────

    private fun Cursor.getStringOrNull(columnName: String): String? {
        val idx = getColumnIndex(columnName)
        return if (idx >= 0 && !isNull(idx)) getString(idx) else null
    }

    private fun Cursor.getLongOrZero(columnName: String): Long {
        val idx = getColumnIndex(columnName)
        return if (idx >= 0 && !isNull(idx)) getLong(idx) else 0L
    }

    private fun Cursor.getIntOrZero(columnName: String): Int {
        val idx = getColumnIndex(columnName)
        return if (idx >= 0 && !isNull(idx)) getInt(idx) else 0
    }

    // ── Internal data classes ─────────────────────────────────────────────

    private data class AlbumInfo(
        val id: String,
        val title: String,
        var count: Int,
        val coverUri: String?
    )

    private data class CollectionInfo(
        val uri: Uri,
        val type: String
    )
}
