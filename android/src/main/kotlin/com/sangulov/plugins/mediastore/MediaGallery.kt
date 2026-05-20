package com.sangulov.plugins.mediastore

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * MediaGallery — бизнес-логика доступа к медиагалерее устройства.
 *
 * Поддерживает три типа медиа:
 *  - photo / video — из `MediaStore.Images` и `MediaStore.Video`
 *  - audio          — из `MediaStore.Audio` (системная музыкальная библиотека)
 *
 * Все публичные методы — `suspend`, чтобы вызывающий плагин запускал их в
 * `Dispatchers.IO` и не блокировал bridge-поток Capacitor.
 */
class MediaGallery(private val context: Context) {

    private val contentResolver: ContentResolver = context.contentResolver

    /** Папка для кешированных миниатюр (внутри cacheDir; Android сам её чистит). */
    private val thumbDir: File by lazy {
        File(context.cacheDir, "mediastore_thumbs").apply { if (!exists()) mkdirs() }
    }

    companion object {
        private const val DEFAULT_THUMB_SIZE = 256

        /** Legacy URI обложек аудио-альбомов — используется на API < 29. */
        @Suppress("DEPRECATION")
        private val ALBUM_ART_URI: Uri = Uri.parse("content://media/external/audio/albumart")

        private val isoFormat: SimpleDateFormat
            get() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
    }

    // ────────────────────────────────────────────────────────────────────────
    // API
    // ────────────────────────────────────────────────────────────────────────

    suspend fun getAlbums(): JSObject = withContext(Dispatchers.IO) {
        val albums = mutableMapOf<String, AlbumInfo>()

        queryAlbumsFrom(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, albums, false)
        queryAlbumsFrom(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, albums, true)

        val arr = JSArray()
        val coverPaths: Map<String, String?> = coroutineScope {
            albums.values.map { info ->
                async(Dispatchers.IO) {
                    val path = if (info.coverUri != null && info.coverId != null) {
                        getOrCreateThumbnailFile(info.coverId, info.coverUri, info.coverIsVideo, DEFAULT_THUMB_SIZE)
                    } else null
                    info.id to path
                }
            }.awaitAll().toMap()
        }

        for (info in albums.values) {
            val obj = JSObject()
            obj.put("id", info.id)
            obj.put("title", info.title)
            obj.put("count", info.count)
            obj.put("coverUri", info.coverUri)
            obj.put("coverWebPath", info.coverUri?.let { contentUriToWebPath(it) })
            obj.put("coverThumbnailWebPath", coverPaths[info.id])
            arr.put(obj)
        }

        JSObject().apply { put("albums", arr) }
    }

    /**
     * Возвращает страницу медиа, отсортированную по дате добавления (DESC).
     *
     * Семантика `albumId`:
     *  - для `photo` / `video` — фильтрует по `BUCKET_ID` (папке галереи).
     *  - для `audio` — игнорируется (у аудио нет «папок» в смысле галереи).
     *  - для `all` — применяется только к photo/video, audio добавляется целиком.
     */
    suspend fun getMedia(albumId: String?, limit: Int, offset: Int, type: String): JSObject = withContext(Dispatchers.IO) {
        // `all` намеренно НЕ включает audio — аудио живёт в отдельной вкладке UI
        // (как в Telegram). Чтобы получить аудио — передавайте `type: 'audio'`.
        val collections = when (type) {
            "photo" -> listOf(CollectionInfo(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "photo"))
            "video" -> listOf(CollectionInfo(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video"))
            "audio" -> listOf(CollectionInfo(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, "audio"))
            else -> listOf(
                CollectionInfo(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "photo"),
                CollectionInfo(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video")
            )
        }

        // 1. total — считаем дёшево, без выборки.
        var total = 0
        for (col in collections) {
            // BUCKET_ID не применяется к audio.
            val filterAlbum = if (col.type == "audio") null else albumId
            total += countMedia(col.uri, filterAlbum)
        }

        // 2. Каждая коллекция отдаёт уже отсортированный курсор с лимитом (offset+limit).
        //    Затем сливаем потоки merge-sort'ом по dateAdded и берём срез [offset, offset+limit).
        val perCollectionTake = offset + limit
        val streams: List<List<JSObject>> = collections.map { col ->
            val filterAlbum = if (col.type == "audio") null else albumId
            queryMediaPage(col.uri, col.type, filterAlbum, perCollectionTake)
        }
        val merged = mergeByCreatedAtDesc(streams)
        val end = minOf(offset + limit, merged.size)
        val page = if (offset < merged.size) merged.subList(offset, end) else emptyList()

        val arr = JSArray()
        for (item in page) arr.put(item)

        JSObject().apply {
            put("media", arr)
            put("total", total)
            put("hasMore", offset + limit < total)
        }
    }

    /**
     * Lazy load thumbnail: возвращает webPath (file URL) и опционально base64.
     * Для аудио возвращает обложку альбома, если она существует.
     */
    suspend fun getThumbnail(id: String, returnBase64: Boolean, size: Int): JSObject = withContext(Dispatchers.IO) {
        val mediaId = id.toLongOrNull() ?: throw IllegalArgumentException("Invalid ID")
        val info = getUriAndType(mediaId) ?: throw IllegalArgumentException("Media not found")

        val effectiveSize = if (size > 0) size else DEFAULT_THUMB_SIZE
        val webPath = getOrCreateThumbnailFile(mediaId, info.uri.toString(), info.isVideo, effectiveSize, info.isAudio, info.albumId) ?: ""
        val base64 = if (returnBase64 && webPath.isNotEmpty()) readCachedAsBase64DataUrl(mediaId, effectiveSize) else ""

        JSObject().apply {
            put("webPath", webPath)
            put("base64String", base64)
        }
    }

    /**
     * Пакетная генерация миниатюр.
     */
    suspend fun getThumbnails(ids: List<String>, size: Int): JSObject = withContext(Dispatchers.IO) {
        val effectiveSize = if (size > 0) size else DEFAULT_THUMB_SIZE

        val results: List<Pair<String, String?>> = coroutineScope {
            ids.map { rawId ->
                async(Dispatchers.IO) {
                    val mediaId = rawId.toLongOrNull() ?: return@async rawId to null
                    val info = getUriAndType(mediaId) ?: return@async rawId to null
                    val path = try {
                        getOrCreateThumbnailFile(mediaId, info.uri.toString(), info.isVideo, effectiveSize, info.isAudio, info.albumId)
                    } catch (_: Exception) { null }
                    rawId to path
                }
            }.awaitAll()
        }

        val map = JSObject()
        for ((rawId, path) in results) {
            if (!path.isNullOrEmpty()) map.put(rawId, path)
        }
        JSObject().apply { put("thumbnails", map) }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Private Logic
    // ────────────────────────────────────────────────────────────────────────

    private data class MediaInfo(val uri: Uri, val isVideo: Boolean, val isAudio: Boolean, val albumId: Long?)

    private fun getUriAndType(id: Long): MediaInfo? {
        val selection = "${MediaStore.MediaColumns._ID} = ?"
        val args = arrayOf(id.toString())
        val projection = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Audio.AudioColumns.ALBUM_ID
        )
        val collection = MediaStore.Files.getContentUri("external")

        contentResolver.query(collection, projection, selection, args, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val typeIdx = cursor.getColumnIndex(MediaStore.Files.FileColumns.MEDIA_TYPE)
                if (typeIdx >= 0) {
                    val type = cursor.getInt(typeIdx)
                    val isVideo = (type == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO)
                    val isAudio = (type == MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO)
                    val albumId = if (isAudio) cursor.getLongOrZero(MediaStore.Audio.AudioColumns.ALBUM_ID).takeIf { it > 0 } else null
                    val contentUri = when {
                        isVideo -> ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                        isAudio -> ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                        else -> ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                    }
                    return MediaInfo(contentUri, isVideo, isAudio, albumId)
                }
            }
        }
        return null
    }

    private fun queryAlbumsFrom(collection: Uri, albums: MutableMap<String, AlbumInfo>, isVideo: Boolean) {
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
                    val coverUri = ContentUris.withAppendedId(collection, mediaId).toString()
                    AlbumInfo(bucketId, bucketName, 0, coverUri, mediaId, isVideo)
                }
                info.count++
            }
        }
    }

    private fun countMedia(collection: Uri, albumId: String?): Int {
        val selection = albumId?.let { "${MediaStore.MediaColumns.BUCKET_ID} = ?" }
        val selectionArgs = albumId?.let { arrayOf(it) }
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        contentResolver.query(collection, projection, selection, selectionArgs, null)?.use { return it.count }
        return 0
    }

    private fun queryMediaPage(collection: Uri, mediaType: String, albumId: String?, take: Int): List<JSObject> {
        val out = mutableListOf<JSObject>()
        val projection = buildMediaProjection(mediaType)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val args = Bundle().apply {
                if (!albumId.isNullOrEmpty()) {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.MediaColumns.BUCKET_ID} = ?")
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(albumId))
                }
                putStringArray(
                    ContentResolver.QUERY_ARG_SORT_COLUMNS,
                    arrayOf(MediaStore.MediaColumns.DATE_ADDED)
                )
                putInt(
                    ContentResolver.QUERY_ARG_SORT_DIRECTION,
                    ContentResolver.QUERY_SORT_DIRECTION_DESCENDING
                )
                putInt(ContentResolver.QUERY_ARG_LIMIT, take)
                putInt(ContentResolver.QUERY_ARG_OFFSET, 0)
            }
            contentResolver.query(collection, projection, args, null)?.use { cursor ->
                while (cursor.moveToNext()) out.add(cursorToMediaItem(cursor, collection, mediaType))
            }
        } else {
            val selection = albumId?.let { "${MediaStore.MediaColumns.BUCKET_ID} = ?" }
            val selectionArgs = albumId?.let { arrayOf(it) }
            val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC LIMIT $take"
            contentResolver.query(collection, projection, selection, selectionArgs, sortOrder)?.use { cursor ->
                while (cursor.moveToNext()) out.add(cursorToMediaItem(cursor, collection, mediaType))
            }
        }
        return out
    }

    /**
     * Сливает несколько уже-DESC-отсортированных списков в один DESC-список по `createdAt`.
     */
    private fun mergeByCreatedAtDesc(streams: List<List<JSObject>>): List<JSObject> {
        if (streams.size == 1) return streams[0]
        val cursors = IntArray(streams.size)
        val totalSize = streams.sumOf { it.size }
        val result = ArrayList<JSObject>(totalSize)
        while (true) {
            var bestIdx = -1
            var bestKey: String? = null
            for (i in streams.indices) {
                if (cursors[i] >= streams[i].size) continue
                val key = streams[i][cursors[i]].optString("createdAt", "")
                if (bestKey == null || key > bestKey) {
                    bestKey = key
                    bestIdx = i
                }
            }
            if (bestIdx == -1) break
            result.add(streams[bestIdx][cursors[bestIdx]])
            cursors[bestIdx]++
        }
        return result
    }

    private fun buildMediaProjection(mediaType: String): Array<String> {
        val base = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED
        )
        if (mediaType != "audio") {
            base.add(MediaStore.MediaColumns.WIDTH)
            base.add(MediaStore.MediaColumns.HEIGHT)
            base.add(MediaStore.MediaColumns.BUCKET_ID)
        }
        when (mediaType) {
            "video" -> base.add(MediaStore.Video.VideoColumns.DURATION)
            "audio" -> {
                base.add(MediaStore.Audio.AudioColumns.DURATION)
                base.add(MediaStore.Audio.AudioColumns.TITLE)
                base.add(MediaStore.Audio.AudioColumns.ARTIST)
                base.add(MediaStore.Audio.AudioColumns.ALBUM)
                base.add(MediaStore.Audio.AudioColumns.ALBUM_ID)
            }
        }
        return base.toTypedArray()
    }

    private fun cursorToMediaItem(cursor: Cursor, collection: Uri, mediaType: String): JSObject {
        val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
        val displayName = cursor.getStringOrNull(MediaStore.MediaColumns.DISPLAY_NAME) ?: ""
        val mimeType = cursor.getStringOrNull(MediaStore.MediaColumns.MIME_TYPE) ?: ""
        val size = cursor.getLongOrZero(MediaStore.MediaColumns.SIZE)
        val width = cursor.getIntOrZero(MediaStore.MediaColumns.WIDTH)
        val height = cursor.getIntOrZero(MediaStore.MediaColumns.HEIGHT)
        val dateAdded = cursor.getLongOrZero(MediaStore.MediaColumns.DATE_ADDED)

        val duration = when (mediaType) {
            "video" -> {
                val col = cursor.getColumnIndex(MediaStore.Video.VideoColumns.DURATION)
                if (col >= 0) cursor.getLong(col) / 1000.0 else 0.0
            }
            "audio" -> {
                val col = cursor.getColumnIndex(MediaStore.Audio.AudioColumns.DURATION)
                if (col >= 0) cursor.getLong(col) / 1000.0 else 0.0
            }
            else -> 0.0
        }

        val contentUri = ContentUris.withAppendedId(collection, id).toString()
        val createdAt = isoFormat.format(Date(dateAdded * 1000))

        val obj = JSObject().apply {
            put("id", id.toString())
            put("type", mediaType)
            put("uri", contentUri)
            put("webPath", contentUriToWebPath(contentUri))
            put("thumbnailUri", null)
            put("thumbnailWebPath", null)
            put("width", width)
            put("height", height)
            put("createdAt", createdAt)
            put("duration", duration)
            put("mimeType", mimeType)
            put("fileSize", size)
            put("fileName", displayName)
        }

        if (mediaType == "audio") {
            obj.put("title", cursor.getStringOrNull(MediaStore.Audio.AudioColumns.TITLE) ?: "")
            obj.put("artist", cursor.getStringOrNull(MediaStore.Audio.AudioColumns.ARTIST) ?: "")
            obj.put("album", cursor.getStringOrNull(MediaStore.Audio.AudioColumns.ALBUM) ?: "")
        }

        return obj
    }

    private fun contentUriToWebPath(contentUri: String): String {
        return if (contentUri.startsWith("content://")) {
            val path = contentUri.removePrefix("content://")
            "https://localhost/_capacitor_content_/$path"
        } else {
            contentUri
        }
    }

    /**
     * Возвращает webPath к закешированному файлу миниатюры (или null).
     * Для аудио пытается загрузить обложку альбома через ALBUM_ART_URI / loadThumbnail.
     */
    private fun getOrCreateThumbnailFile(
        mediaId: Long,
        contentUriStr: String,
        isVideo: Boolean,
        size: Int = DEFAULT_THUMB_SIZE,
        isAudio: Boolean = false,
        audioAlbumId: Long? = null
    ): String? {
        val thumbFile = File(thumbDir, "thumb_${mediaId}_${size}.jpg")
        if (thumbFile.exists() && thumbFile.length() > 0) {
            return "https://localhost/_capacitor_file_" + thumbFile.absolutePath
        }

        try {
            val contentUri = Uri.parse(contentUriStr)
            var bitmap: Bitmap? = null

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    bitmap = contentResolver.loadThumbnail(contentUri, Size(size, size), null)
                } catch (_: Exception) { }
            }
            if (bitmap == null && isAudio && audioAlbumId != null) {
                // Fallback на legacy ALBUM_ART_URI для API < 29.
                try {
                    val artUri = ContentUris.withAppendedId(ALBUM_ART_URI, audioAlbumId)
                    contentResolver.openInputStream(artUri)?.use { input ->
                        bitmap = android.graphics.BitmapFactory.decodeStream(input)
                    }
                } catch (_: Exception) { }
            }
            if (bitmap == null && !isAudio) {
                if (isVideo) {
                    @Suppress("DEPRECATION")
                    bitmap = MediaStore.Video.Thumbnails.getThumbnail(contentResolver, mediaId, MediaStore.Video.Thumbnails.MINI_KIND, null)
                } else {
                    @Suppress("DEPRECATION")
                    bitmap = MediaStore.Images.Thumbnails.getThumbnail(contentResolver, mediaId, MediaStore.Images.Thumbnails.MINI_KIND, null)
                }
            }

            if (bitmap != null) {
                FileOutputStream(thumbFile).use { out -> bitmap!!.compress(Bitmap.CompressFormat.JPEG, 70, out) }
                return "https://localhost/_capacitor_file_" + thumbFile.absolutePath
            }
        } catch (_: Exception) { }
        return null
    }

    private fun readCachedAsBase64DataUrl(mediaId: Long, size: Int): String {
        val thumbFile = File(thumbDir, "thumb_${mediaId}_${size}.jpg")
        if (!thumbFile.exists()) return ""
        return try {
            FileInputStream(thumbFile).use { fis ->
                val baos = ByteArrayOutputStream(thumbFile.length().toInt().coerceAtLeast(1024))
                val buf = ByteArray(8 * 1024)
                while (true) {
                    val n = fis.read(buf); if (n <= 0) break
                    baos.write(buf, 0, n)
                }
                val b64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                "data:image/jpeg;base64,$b64"
            }
        } catch (_: Exception) { "" }
    }

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

    private data class AlbumInfo(val id: String, val title: String, var count: Int, val coverUri: String?, val coverId: Long?, val coverIsVideo: Boolean)
    private data class CollectionInfo(val uri: Uri, val type: String)
}
