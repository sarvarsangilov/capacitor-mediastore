package com.sangulov.plugins.mediastore

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Base64
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.min

/**
 * FilePicker — управление «недавно выбранными» файлами.
 *
 * Жизненный цикл записи:
 *  1. Пользователь выбирает файл через `ACTION_OPEN_DOCUMENT` (системный пикер).
 *  2. Плагин вызывает [persist], который:
 *      - берёт persistable read permission через `takePersistableUriPermission`,
 *      - читает метаданные (имя, размер, MIME),
 *      - сохраняет запись в SharedPreferences (JSON-массив).
 *  3. При следующем запуске приложения [list] вернёт ту же запись с актуальным
 *     `webPath`. Чтение файла из JS работает без повторного диалога.
 *  4. [remove] / [clear] отзывают permission и удаляют запись из хранилища.
 *
 * Хранилище — SharedPreferences (`mediastore_recent_files.xml`), значения —
 * JSON-массив объектов `RecentEntry`. Простое, durable, не требует Room.
 */
class FilePicker(private val context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("mediastore_recent_files", Context.MODE_PRIVATE)

    companion object {
        private const val KEY_ENTRIES = "entries"
        private const val DEFAULT_CHUNK_BYTES = 1 * 1024 * 1024 // 1 MB
        private const val MAX_CHUNK_BYTES = 8 * 1024 * 1024     // 8 MB (защита от OOM)

        private val isoFormat: SimpleDateFormat
            get() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Public API
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Строит Intent для системного пикера. `mimeTypes` пуст → "*/*".
     */
    fun buildPickIntent(mimeTypes: List<String>, multiple: Boolean): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = when {
                mimeTypes.isEmpty() -> "*/*"
                mimeTypes.size == 1 -> mimeTypes[0]
                else -> "*/*"
            }
            if (mimeTypes.size > 1) {
                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
            if (multiple) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
    }

    /**
     * Извлекает URI из результата пикера (single и multiple).
     */
    fun extractUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val list = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i).uri?.let { list.add(it) }
            }
        } else {
            data.data?.let { list.add(it) }
        }
        return list
    }

    /**
     * Берёт persistable permission, читает метаданные и сохраняет запись.
     * Если запись с таким URI уже была — обновляет lastAccessedAt.
     */
    suspend fun persist(uris: List<Uri>): List<JSObject> = withContext(Dispatchers.IO) {
        if (uris.isEmpty()) return@withContext emptyList()
        val now = isoFormat.format(Date())
        val all = readAll().associateBy { it.uri }.toMutableMap()
        val out = mutableListOf<JSObject>()

        for (uri in uris) {
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: SecurityException) {
                // некоторые провайдеры не выдают persistable permission — пропускаем,
                // запись всё равно может остаться рабочей в рамках одной сессии.
            }

            val meta = readMetadata(uri)
            val key = uri.toString()
            val existing = all[key]
            val entry = RecentEntry(
                id = key,
                uri = key,
                fileName = meta.fileName,
                mimeType = meta.mimeType,
                fileSize = meta.fileSize,
                pickedAt = existing?.pickedAt ?: now,
                lastAccessedAt = now
            )
            all[key] = entry
            out.add(entry.toJSObject())
        }

        writeAll(all.values.toList())
        out
    }

    /**
     * Возвращает страницу «недавних» с фильтром по MIME.
     * Параллельно проверяет, что каждый URI всё ещё доступен — недоступные
     * записи **молча выбрасываются** из хранилища.
     */
    suspend fun list(limit: Int, offset: Int, mimeFilters: List<String>): JSObject = withContext(Dispatchers.IO) {
        val (alive, dead) = readAll().partition { isAccessible(Uri.parse(it.uri)) }
        if (dead.isNotEmpty()) writeAll(alive)

        val filtered = if (mimeFilters.isEmpty()) alive
        else alive.filter { entry -> mimeFilters.any { matchesMime(entry.mimeType, it) } }

        val sorted = filtered.sortedByDescending { it.lastAccessedAt }
        val total = sorted.size
        val end = minOf(offset + limit, total)
        val page = if (offset < total) sorted.subList(offset, end) else emptyList()

        val arr = JSArray()
        for (entry in page) arr.put(entry.toJSObject())
        JSObject().apply {
            put("files", arr)
            put("total", total)
            put("hasMore", offset + limit < total)
        }
    }

    /**
     * Резолвит конкретную запись: обновляет lastAccessedAt и возвращает её.
     * Возвращает `null`, если запись больше недоступна.
     */
    suspend fun resolve(id: String): JSObject? = withContext(Dispatchers.IO) {
        val all = readAll().toMutableList()
        val idx = all.indexOfFirst { it.id == id }
        if (idx < 0) return@withContext null

        val entry = all[idx]
        val uri = Uri.parse(entry.uri)
        if (!isAccessible(uri)) {
            all.removeAt(idx)
            writeAll(all)
            return@withContext null
        }

        val updated = entry.copy(lastAccessedAt = isoFormat.format(Date()))
        all[idx] = updated
        writeAll(all)
        updated.toJSObject()
    }

    /**
     * Убирает одну запись из хранилища + отзывает persistable permission.
     */
    suspend fun remove(id: String) = withContext(Dispatchers.IO) {
        val all = readAll().toMutableList()
        val idx = all.indexOfFirst { it.id == id }
        if (idx < 0) return@withContext
        val entry = all.removeAt(idx)
        try {
            context.contentResolver.releasePersistableUriPermission(
                Uri.parse(entry.uri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: Exception) { }
        writeAll(all)
    }

    /**
     * Streaming-чтение фрагмента файла из «недавних».
     *
     * Открывает InputStream через ContentResolver (URI с persistable permission),
     * пропускает `offset` байт, читает максимум `length`, возвращает base64.
     * Поток закрывается сразу после чтения — никаких долгоживущих хендлов.
     */
    suspend fun readFileChunk(id: String, offset: Long, length: Int): JSObject = withContext(Dispatchers.IO) {
        val entries = readAll()
        val entry = entries.firstOrNull { it.id == id }
            ?: throw IllegalArgumentException("Recent file not found")
        val uri = Uri.parse(entry.uri)
        val totalSize = entry.fileSize

        val safeOffset = max(0L, offset)
        val safeLength = if (length <= 0) DEFAULT_CHUNK_BYTES else min(length, MAX_CHUNK_BYTES)

        val buf = ByteArray(safeLength)
        var read = 0
        val stream: InputStream = context.contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("Cannot open stream for $uri")
        stream.use { s ->
            // skip(offset) может вернуть меньше; повторяем.
            var remaining = safeOffset
            while (remaining > 0) {
                val skipped = s.skip(remaining)
                if (skipped <= 0) break
                remaining -= skipped
            }
            // Заполняем буфер до safeLength или EOF.
            while (read < safeLength) {
                val n = s.read(buf, read, safeLength - read)
                if (n <= 0) break
                read += n
            }
        }

        val data = if (read > 0) {
            Base64.encodeToString(buf, 0, read, Base64.NO_WRAP)
        } else ""

        val eof: Boolean = if (totalSize > 0) {
            safeOffset + read >= totalSize
        } else {
            // Если totalSize неизвестен — определяем по факту короткого чтения.
            read < safeLength
        }

        JSObject().apply {
            put("data", data)
            put("bytesRead", read)
            put("eof", eof)
            put("totalSize", totalSize)
        }
    }

    /**
     * Очищает всё: отзывает все permissions, удаляет запись из хранилища.
     */
    suspend fun clear() = withContext(Dispatchers.IO) {
        val all = readAll()
        for (entry in all) {
            try {
                context.contentResolver.releasePersistableUriPermission(
                    Uri.parse(entry.uri),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) { }
        }
        prefs.edit().remove(KEY_ENTRIES).apply()
    }

    // ────────────────────────────────────────────────────────────────────────
    // Private
    // ────────────────────────────────────────────────────────────────────────

    private data class FileMetadata(val fileName: String, val mimeType: String, val fileSize: Long)

    private fun readMetadata(uri: Uri): FileMetadata {
        var name = uri.lastPathSegment ?: "file"
        var size = 0L
        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"

        try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0 && !cursor.isNull(nameIdx)) name = cursor.getString(nameIdx)
                    if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) size = cursor.getLong(sizeIdx)
                }
            }
        } catch (_: Exception) { }

        return FileMetadata(name, mime, size)
    }

    /**
     * Дёшево проверяет доступность URI — пробует открыть курсор.
     * Если файл удалён или permission отозван — система кинет
     * SecurityException / возвращает null, что мы трактуем как «недоступен».
     */
    private fun isAccessible(uri: Uri): Boolean {
        return try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { it.moveToFirst() } ?: false
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    /** Поддерживает точные значения (`application/pdf`) и wildcards (`image/*`). */
    private fun matchesMime(mime: String, pattern: String): Boolean {
        if (pattern == "*/*") return true
        if (pattern.endsWith("/*")) {
            val prefix = pattern.removeSuffix("/*")
            return mime.startsWith("$prefix/")
        }
        return mime.equals(pattern, ignoreCase = true)
    }

    private fun readAll(): List<RecentEntry> {
        val raw = prefs.getString(KEY_ENTRIES, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                try { RecentEntry.fromJson(arr.getJSONObject(i)) } catch (_: Exception) { null }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun writeAll(entries: List<RecentEntry>) {
        val arr = JSONArray()
        for (entry in entries) arr.put(entry.toJsonObject())
        prefs.edit().putString(KEY_ENTRIES, arr.toString()).apply()
    }

    private data class RecentEntry(
        val id: String,
        val uri: String,
        val fileName: String,
        val mimeType: String,
        val fileSize: Long,
        val pickedAt: String,
        val lastAccessedAt: String
    ) {
        fun toJsonObject(): JSONObject = JSONObject().apply {
            put("id", id)
            put("uri", uri)
            put("fileName", fileName)
            put("mimeType", mimeType)
            put("fileSize", fileSize)
            put("pickedAt", pickedAt)
            put("lastAccessedAt", lastAccessedAt)
        }

        fun toJSObject(): JSObject = JSObject().apply {
            put("id", id)
            put("uri", uri)
            put("webPath", contentUriToWebPath(uri))
            put("fileName", fileName)
            put("mimeType", mimeType)
            put("fileSize", fileSize)
            put("pickedAt", pickedAt)
            put("lastAccessedAt", lastAccessedAt)
        }

        companion object {
            fun fromJson(o: JSONObject): RecentEntry = RecentEntry(
                id = o.getString("id"),
                uri = o.getString("uri"),
                fileName = o.optString("fileName", ""),
                mimeType = o.optString("mimeType", "application/octet-stream"),
                fileSize = o.optLong("fileSize", 0L),
                pickedAt = o.optString("pickedAt", ""),
                lastAccessedAt = o.optString("lastAccessedAt", "")
            )

            private fun contentUriToWebPath(uri: String): String {
                return if (uri.startsWith("content://")) {
                    "https://localhost/_capacitor_content_/" + uri.removePrefix("content://")
                } else uri
            }
        }
    }
}
