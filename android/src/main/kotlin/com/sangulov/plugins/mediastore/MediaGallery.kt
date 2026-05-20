package com.sangulov.plugins.mediastore

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.util.Size
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * MediaGallery — бизнес-логика доступа к медиагалерее устройства.
 *
 * Поддерживает три типа медиа:
 *  - photo / video — из `MediaStore.Images` и `MediaStore.Video`
 *  - audio          — из `MediaStore.Audio` (системная музыкальная библиотека)
 *
 * Ключевые оптимизации:
 *  - WebP для миниатюр (на 25–30% меньше JPEG, быстрее decode на webview).
 *  - `Semaphore(6)` для пакетных запросов миниатюр — не перегружает IO-пул.
 *  - Cursor-based pagination для гигантских галерей (O(log n) против O(offset)).
 *  - Поддержка density: миниатюра хранится в `size * density` пикселях,
 *    чтобы на 3x-экранах не было апскейл-замыливания.
 *  - Все публичные методы — `suspend`, корректно реагируют на cancellation
 *    (см. [CapacitorMediastorePlugin.cancelPendingThumbnails]).
 */
class MediaGallery(private val context: Context) {

    private val contentResolver: ContentResolver = context.contentResolver

    /** Папка для кешированных миниатюр (внутри cacheDir; Android сам её чистит). */
    private val thumbDir: File by lazy {
        File(context.cacheDir, "mediastore_thumbs").apply { if (!exists()) mkdirs() }
    }

    /**
     * Ограничивает параллелизм миниатюр-декодов. 6 одновременных задач — sweet spot
     * между throughput и risk-of-jank на mid-tier устройствах.
     */
    private val thumbnailSemaphore = Semaphore(6)

    companion object {
        private const val TAG = "CapacitorMediastore"
        private const val DEFAULT_THUMB_SIZE = 256
        private const val THUMB_QUALITY = 75

        /** Legacy URI обложек аудио-альбомов — используется на API < 29. */
        @Suppress("DEPRECATION")
        private val ALBUM_ART_URI: Uri = Uri.parse("content://media/external/audio/albumart")

        private val isoFormat: SimpleDateFormat
            get() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }

        /**
         * `Bitmap.CompressFormat.WEBP_LOSSY` доступен с API 30 (Android 11).
         * На более старых API используем deprecated `WEBP` с тем же качеством.
         */
        @Suppress("DEPRECATION")
        private val WEBP_FORMAT: Bitmap.CompressFormat =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Bitmap.CompressFormat.WEBP_LOSSY
            else Bitmap.CompressFormat.WEBP
    }

    // ────────────────────────────────────────────────────────────────────────
    // Albums
    // ────────────────────────────────────────────────────────────────────────

    suspend fun getAlbums(): JSObject = withContext(Dispatchers.IO) {
        val albums = mutableMapOf<String, AlbumInfo>()

        queryAlbumsFrom(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, albums, false)
        queryAlbumsFrom(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, albums, true)

        val arr = JSArray()
        val coverPaths: Map<String, String?> = coroutineScope {
            albums.values.map { info ->
                async(Dispatchers.IO) {
                    thumbnailSemaphore.withPermit {
                        if (info.coverUri != null && info.coverId != null) {
                            getOrCreateThumbnailFile(
                                info.coverId, info.coverUri, info.coverIsVideo, DEFAULT_THUMB_SIZE, 1.0
                            )
                        } else null
                    }.let { path -> info.id to path }
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

    // ────────────────────────────────────────────────────────────────────────
    // Media (offset + cursor pagination)
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Семантика `albumId`:
     *  - для `photo` / `video` — фильтрует по `BUCKET_ID` (папке галереи).
     *  - для `audio` — игнорируется (у аудио нет «папок» в смысле галереи).
     *  - для `all` — применяется только к photo/video.
     *
     * Семантика `cursor`:
     *  - если передан — используется cursor-based pagination (O(log n)).
     *  - если пуст — используется offset-режим (offset/limit).
     */
    suspend fun getMedia(
        albumId: String?,
        limit: Int,
        offset: Int,
        type: String,
        cursor: String?
    ): JSObject = withContext(Dispatchers.IO) {
        Log.d(TAG, "getMedia: type=$type, albumId=$albumId, limit=$limit, offset=$offset, cursor=${cursor != null}")
        val collections = when (type) {
            "photo" -> listOf(CollectionInfo(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "photo"))
            "video" -> listOf(CollectionInfo(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video"))
            "audio" -> listOf(CollectionInfo(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, "audio"))
            else -> listOf(
                CollectionInfo(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "photo"),
                CollectionInfo(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video")
            )
        }

        var total = 0
        for (col in collections) {
            val filterAlbum = if (col.type == "audio") null else albumId
            val c = countMedia(col.uri, filterAlbum)
            Log.d(TAG, "getMedia: countMedia(${col.type}) = $c")
            total += c
        }

        val cursorPos: CursorPosition? = if (cursor.isNullOrEmpty()) null else decodeCursor(cursor)
        val perCollectionTake = if (cursorPos != null) limit else (offset + limit)

        val streams: List<List<JSObject>> = collections.map { col ->
            val filterAlbum = if (col.type == "audio") null else albumId
            queryMediaPage(col.uri, col.type, filterAlbum, perCollectionTake, cursorPos)
        }
        val merged = mergeByCreatedAtDesc(streams)

        val page: List<JSObject> = if (cursorPos != null) {
            // cursor-режим: страница уже отфильтрована на уровне SQL, режем по limit.
            merged.take(limit)
        } else {
            val end = minOf(offset + limit, merged.size)
            if (offset < merged.size) merged.subList(offset, end) else emptyList()
        }

        val arr = JSArray()
        for (item in page) arr.put(item)

        // Следующий курсор — last item в странице.
        val nextCursor: String? = if (page.isNotEmpty() && page.size == limit) {
            val last = page.last()
            val lastDate = last.optString("_dateAddedRaw", "0").toLongOrNull() ?: 0L
            val lastId = last.optString("id", "0")
            // Удаляем служебное поле перед отдачей.
            for (i in 0 until arr.length()) {
                (arr.get(i) as JSObject).remove("_dateAddedRaw")
            }
            encodeCursor(CursorPosition(lastDate, lastId))
        } else {
            for (i in 0 until arr.length()) {
                (arr.get(i) as JSObject).remove("_dateAddedRaw")
            }
            null
        }

        val hasMore: Boolean = if (cursorPos != null) {
            nextCursor != null
        } else {
            offset + limit < total
        }

        JSObject().apply {
            put("media", arr)
            put("total", total)
            put("hasMore", hasMore)
            put("nextCursor", nextCursor)
        }
    }

    /**
     * Дешёвая проверка: есть ли в коллекции хотя бы один файл?
     * На API 30+ использует `QUERY_ARG_LIMIT=1`, на старых — обычный count.
     */
    suspend fun hasMedia(type: String): Boolean = withContext(Dispatchers.IO) {
        val uris = when (type) {
            "photo" -> listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
            "video" -> listOf(MediaStore.Video.Media.EXTERNAL_CONTENT_URI)
            "audio" -> listOf(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI)
            else -> listOf(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            )
        }
        for (uri in uris) {
            val projection = arrayOf(MediaStore.MediaColumns._ID)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val args = Bundle().apply { putInt(ContentResolver.QUERY_ARG_LIMIT, 1) }
                contentResolver.query(uri, projection, args, null)?.use { c ->
                    if (c.moveToFirst()) return@withContext true
                }
            } else {
                contentResolver.query(uri, projection, null, null, "_id DESC LIMIT 1")?.use { c ->
                    if (c.moveToFirst()) return@withContext true
                }
            }
        }
        false
    }

    // ────────────────────────────────────────────────────────────────────────
    // Resolve full-size path (для совместимости с iOS API; на Android уже есть)
    // ────────────────────────────────────────────────────────────────────────

    suspend fun resolveMediaPath(id: String): JSObject = withContext(Dispatchers.IO) {
        val mediaId = id.toLongOrNull() ?: throw IllegalArgumentException("Invalid ID")
        val info = getUriAndType(mediaId) ?: throw IllegalArgumentException("Media not found")
        JSObject().apply {
            put("uri", info.uri.toString())
            put("webPath", contentUriToWebPath(info.uri.toString()))
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Thumbnails (Lazy Load + Prefetch + Cancellation)
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Lazy-load одной миниатюры. Cancellation-aware.
     */
    suspend fun getThumbnail(id: String, returnBase64: Boolean, size: Int, density: Double): JSObject = withContext(Dispatchers.IO) {
        val mediaId = id.toLongOrNull() ?: throw IllegalArgumentException("Invalid ID")
        val info = getUriAndType(mediaId) ?: throw IllegalArgumentException("Media not found")

        val effectiveSize = effectiveThumbSize(size, density)
        val webPath = thumbnailSemaphore.withPermit {
            currentCoroutineContext().ensureActive()
            getOrCreateThumbnailFile(
                mediaId, info.uri.toString(), info.isVideo, effectiveSize, 1.0, info.isAudio, info.albumId
            )
        } ?: ""
        val base64 = if (returnBase64 && webPath.isNotEmpty()) readCachedAsBase64DataUrl(mediaId, effectiveSize) else ""

        JSObject().apply {
            put("webPath", webPath)
            put("base64String", base64)
        }
    }

    /**
     * Пакетная генерация миниатюр. Cancellation-aware: если родительский Job
     * отменён через [CapacitorMediastorePlugin.cancelPendingThumbnails], уже
     * не запущенные задачи прерываются, готовые — остаются в кеше.
     */
    suspend fun getThumbnails(ids: List<String>, size: Int, density: Double): JSObject = withContext(Dispatchers.IO) {
        val effectiveSize = effectiveThumbSize(size, density)

        val results: List<Pair<String, String?>> = coroutineScope {
            ids.map { rawId ->
                async(Dispatchers.IO) {
                    thumbnailSemaphore.withPermit {
                        if (!isActive) return@async rawId to null
                        val mediaId = rawId.toLongOrNull() ?: return@async rawId to null
                        val info = try {
                            getUriAndType(mediaId)
                        } catch (e: CancellationException) { throw e }
                          catch (e: Exception) {
                              Log.w(TAG, "getThumbnails: getUriAndType failed for id=$mediaId: ${e.message}")
                              null
                          } ?: return@async rawId to null
                        val path = try {
                            getOrCreateThumbnailFile(
                                mediaId, info.uri.toString(), info.isVideo, effectiveSize, 1.0, info.isAudio, info.albumId
                            )
                        } catch (e: CancellationException) { throw e }
                          catch (_: Exception) { null }
                        rawId to path
                    }
                }
            }.awaitAll()
        }

        val map = JSObject()
        for ((rawId, path) in results) {
            if (!path.isNullOrEmpty()) map.put(rawId, path)
        }
        JSObject().apply { put("thumbnails", map) }
    }

    /**
     * Прогревает кеш миниатюр в фоне — НЕ блокирует caller'а.
     * Идентичен `getThumbnails`, но результат не возвращается.
     */
    suspend fun prefetchThumbnails(ids: List<String>, size: Int, density: Double) {
        val effectiveSize = effectiveThumbSize(size, density)
        coroutineScope {
            ids.forEach { rawId ->
                launch(Dispatchers.IO) {
                    thumbnailSemaphore.withPermit {
                        if (!isActive) return@withPermit
                        val mediaId = rawId.toLongOrNull() ?: return@withPermit
                        val info = getUriAndType(mediaId) ?: return@withPermit
                        try {
                            getOrCreateThumbnailFile(
                                mediaId, info.uri.toString(), info.isVideo, effectiveSize, 1.0, info.isAudio, info.albumId
                            )
                        } catch (_: Exception) { /* swallow */ }
                    }
                }
            }
        }
    }

    private fun effectiveThumbSize(size: Int, density: Double): Int {
        val s = if (size > 0) size else DEFAULT_THUMB_SIZE
        val d = if (density > 0) density else 1.0
        return (s * d).roundToInt().coerceAtLeast(32)
    }

    // ────────────────────────────────────────────────────────────────────────
    // Private query logic
    // ────────────────────────────────────────────────────────────────────────

    private data class MediaInfo(val uri: Uri, val isVideo: Boolean, val isAudio: Boolean, val albumId: Long?)

    /**
     * Определяет тип медиа (image / video / audio) по числовому ID.
     * MediaStore.Files — унифицированная таблица всех файлов, но у неё **нет**
     * audio-специфичных колонок (album_id и т.п.). Поэтому делаем два запроса:
     *  1. Files → media_type (определяем категорию)
     *  2. Audio → album_id (только если файл оказался audio)
     */
    private fun getUriAndType(id: Long): MediaInfo? {
        val selection = "${MediaStore.MediaColumns._ID} = ?"
        val args = arrayOf(id.toString())
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE)

        var isVideo = false
        var isAudio = false
        var found = false

        try {
            contentResolver.query(collection, projection, selection, args, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val typeIdx = cursor.getColumnIndex(MediaStore.Files.FileColumns.MEDIA_TYPE)
                    if (typeIdx >= 0) {
                        val type = cursor.getInt(typeIdx)
                        isVideo = (type == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO)
                        isAudio = (type == MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO)
                        found = true
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getUriAndType: Files query failed for id=$id: ${e.message}")
            return null
        }
        if (!found) return null

        val albumId: Long? = if (isAudio) queryAudioAlbumId(id) else null
        val contentUri = when {
            isVideo -> ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
            isAudio -> ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
            else -> ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        }
        return MediaInfo(contentUri, isVideo, isAudio, albumId)
    }

    /**
     * Достаёт album_id для аудио-файла отдельным запросом в Audio-коллекцию.
     */
    private fun queryAudioAlbumId(id: Long): Long? {
        return try {
            val selection = "${MediaStore.MediaColumns._ID} = ?"
            val args = arrayOf(id.toString())
            val projection = arrayOf(MediaStore.Audio.AudioColumns.ALBUM_ID)
            contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, projection, selection, args, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(MediaStore.Audio.AudioColumns.ALBUM_ID)
                    if (idx >= 0 && !cursor.isNull(idx)) return@use cursor.getLong(idx).takeIf { it > 0 }
                }
                null
            }
        } catch (_: Exception) { null }
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

    /**
     * Курсор-страница, отсортированная по `(DATE_ADDED DESC, _ID DESC)`.
     * Поддерживает album-filter и cursor (`date < ? OR (date = ? AND _id < ?)`).
     */
    private fun queryMediaPage(
        collection: Uri,
        mediaType: String,
        albumId: String?,
        take: Int,
        cursor: CursorPosition?
    ): List<JSObject> {
        val out = mutableListOf<JSObject>()
        val projection = buildMediaProjection(mediaType)

        // Build selection
        val selParts = mutableListOf<String>()
        val selArgs = mutableListOf<String>()
        if (!albumId.isNullOrEmpty()) {
            selParts.add("${MediaStore.MediaColumns.BUCKET_ID} = ?")
            selArgs.add(albumId)
        }
        if (cursor != null) {
            selParts.add(
                "(${MediaStore.MediaColumns.DATE_ADDED} < ? OR " +
                    "(${MediaStore.MediaColumns.DATE_ADDED} = ? AND ${MediaStore.MediaColumns._ID} < ?))"
            )
            selArgs.add(cursor.dateAdded.toString())
            selArgs.add(cursor.dateAdded.toString())
            selArgs.add(cursor.lastId)
        }
        val selection = if (selParts.isEmpty()) null else selParts.joinToString(" AND ")
        val selectionArgs = if (selArgs.isEmpty()) null else selArgs.toTypedArray()

        // Sort + limit. На API 26+ можно использовать Bundle-аргументы.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // ВАЖНО: только ОДНА колонка в QUERY_ARG_SORT_COLUMNS.
            // Multi-column sort через структурированный API MediaStore-провайдер
            // молча игнорирует на ряде Android-версий — приходит дефолтный порядок
            // (ASC по _id), что ломает merge-сортировку. Tie-breaker по _id для
            // cursor-пагинации обеспечивается на уровне SQL WHERE, см. cursor-логику.
            val args = Bundle().apply {
                if (selection != null) {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
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
            contentResolver.query(collection, projection, args, null)?.use { c ->
                Log.d(TAG, "queryMediaPage[$mediaType]: cursor=${c.count} rows, take=$take")
                while (c.moveToNext()) out.add(cursorToMediaItem(c, collection, mediaType))
            }
        } else {
            val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC LIMIT $take"
            contentResolver.query(collection, projection, selection, selectionArgs, sortOrder)?.use { c ->
                Log.d(TAG, "queryMediaPage[$mediaType] (legacy): cursor=${c.count} rows, take=$take")
                while (c.moveToNext()) out.add(cursorToMediaItem(c, collection, mediaType))
            }
        }
        return out
    }

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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                base.add(MediaStore.MediaColumns.ORIENTATION)
            }
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
        var width = cursor.getIntOrZero(MediaStore.MediaColumns.WIDTH)
        var height = cursor.getIntOrZero(MediaStore.MediaColumns.HEIGHT)
        val dateAdded = cursor.getLongOrZero(MediaStore.MediaColumns.DATE_ADDED)
        val orientation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && mediaType != "audio") {
            cursor.getIntOrZero(MediaStore.MediaColumns.ORIENTATION)
        } else 0

        // На некоторых девайсах WIDTH/HEIGHT в MediaStore до-rotation; нормализуем.
        if (orientation == 90 || orientation == 270) {
            val tmp = width; width = height; height = tmp
        }

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
            put("orientation", orientation)
            put("isLivePhoto", false)
            put("isHDR", false)
            put("createdAt", createdAt)
            put("duration", duration)
            put("mimeType", mimeType)
            put("fileSize", size)
            put("fileName", displayName)
            // Служебное поле — снимается перед отдачей в JS.
            put("_dateAddedRaw", dateAdded.toString())
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

    // ────────────────────────────────────────────────────────────────────────
    // Thumbnail file generation (WebP)
    // ────────────────────────────────────────────────────────────────────────

    private fun getOrCreateThumbnailFile(
        mediaId: Long,
        contentUriStr: String,
        isVideo: Boolean,
        size: Int = DEFAULT_THUMB_SIZE,
        @Suppress("UNUSED_PARAMETER") legacyDensity: Double = 1.0,
        isAudio: Boolean = false,
        audioAlbumId: Long? = null
    ): String? {
        val thumbFile = File(thumbDir, "thumb_${mediaId}_${size}.webp")
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
                try {
                    val artUri = ContentUris.withAppendedId(ALBUM_ART_URI, audioAlbumId)
                    contentResolver.openInputStream(artUri)?.use { input ->
                        bitmap = BitmapFactory.decodeStream(input)
                    }
                } catch (_: Exception) { }
            }
            if (bitmap == null && isVideo) {
                // Надёжный fallback для видео: вытаскиваем кадр через
                // MediaMetadataRetriever. Срабатывает даже когда у MediaStore нет
                // предсгенерированной превьюшки (loadThumbnail в этом случае
                // бросает FileNotFoundException, которая ловится Android'ом и
                // громко логгируется системой, даже если мы её catch'нули).
                bitmap = extractVideoFrame(contentUri, size)
            }
            if (bitmap == null && !isAudio && !isVideo && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                // Legacy image thumbnails только для очень старых Android.
                // На Q+ это deprecated и flaky.
                @Suppress("DEPRECATION")
                bitmap = MediaStore.Images.Thumbnails.getThumbnail(
                    contentResolver, mediaId, MediaStore.Images.Thumbnails.MINI_KIND, null
                )
            }

            if (bitmap != null) {
                FileOutputStream(thumbFile).use { out ->
                    bitmap!!.compress(WEBP_FORMAT, THUMB_QUALITY, out)
                }
                return "https://localhost/_capacitor_file_" + thumbFile.absolutePath
            }
        } catch (_: Exception) { }
        return null
    }

    /**
     * Вытаскивает один кадр из видео через MediaMetadataRetriever и масштабирует
     * под нужный `size`. Возвращает `null`, если видео битое / закрыто / в облаке
     * без локальной копии.
     *
     * Используется как fallback после неудачного `loadThumbnail`.
     */
    private fun extractVideoFrame(uri: Uri, size: Int): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            // Берём кадр на 1-й секунде через CLOSEST_SYNC — даёт ключевой кадр
            // быстро и без артефактов B-frame'ов.
            val raw: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(
                    1_000_000L,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    size, size
                )
            } else {
                retriever.getFrameAtTime(1_000_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
            // Если первый кадр не сошёл — пробуем «любой кадр» без time-преференса.
            raw ?: retriever.getFrameAtTime(-1L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (_: Exception) {
            null
        } finally {
            try { retriever.release() } catch (_: Exception) { }
        }
    }

    private fun readCachedAsBase64DataUrl(mediaId: Long, size: Int): String {
        val thumbFile = File(thumbDir, "thumb_${mediaId}_${size}.webp")
        if (!thumbFile.exists()) return ""
        return try {
            FileInputStream(thumbFile).use { fis ->
                val baos = ByteArrayOutputStream(max(thumbFile.length().toInt(), 1024))
                val buf = ByteArray(8 * 1024)
                while (true) {
                    val n = fis.read(buf); if (n <= 0) break
                    baos.write(buf, 0, n)
                }
                val b64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                "data:image/webp;base64,$b64"
            }
        } catch (_: Exception) { "" }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Cursor encoding
    // ────────────────────────────────────────────────────────────────────────

    private data class CursorPosition(val dateAdded: Long, val lastId: String)

    private fun encodeCursor(pos: CursorPosition): String {
        val raw = JSONObject().apply {
            put("d", pos.dateAdded)
            put("i", pos.lastId)
        }.toString()
        return Base64.encodeToString(raw.toByteArray(), Base64.NO_WRAP or Base64.URL_SAFE)
    }

    private fun decodeCursor(token: String): CursorPosition? {
        return try {
            val raw = String(Base64.decode(token, Base64.NO_WRAP or Base64.URL_SAFE))
            val obj = JSONObject(raw)
            CursorPosition(obj.getLong("d"), obj.getString("i"))
        } catch (_: Exception) {
            null
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Cursor helpers
    // ────────────────────────────────────────────────────────────────────────

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
