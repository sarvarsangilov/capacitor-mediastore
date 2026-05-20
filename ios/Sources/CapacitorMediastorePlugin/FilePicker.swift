import Foundation
import UIKit
import UniformTypeIdentifiers

/**
 * FilePicker — управление «недавно выбранными» файлами на iOS.
 *
 * Жизненный цикл записи:
 *  1. Пользователь выбирает файл через `UIDocumentPickerViewController`.
 *  2. Для каждого URL берётся security-scoped доступ
 *     (`startAccessingSecurityScopedResource`), создаётся bookmark с
 *     включёнными security-scope.
 *  3. Bookmark + метаданные сохраняются в JSON-файле в Application Support.
 *  4. При следующем запуске приложения [list] резолвит bookmark, проверяет
 *     `isStale` и обновляет его при необходимости. Доступ к файлу
 *     восстанавливается без повторного диалога.
 *  5. [remove] / [clear] удаляют bookmark из хранилища.
 *
 * Все операции с bookmark делаются на background-очереди, JSON-файл пишется
 * атомарно (`Data.write(.atomic)`) — гонок гарантированно нет.
 */
final class FilePicker: NSObject {

    /// Singleton-инстанс, чтобы делегат пикера не освобождался
    /// до возврата управления из системного UI.
    static let shared = FilePicker()

    private let queue = DispatchQueue(label: "com.sangulov.plugins.mediastore.filepicker", attributes: .concurrent)
    private let writeLock = NSLock()

    /// Путь к JSON-файлу с записями.
    private lazy var storeURL: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("CapacitorMediastore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent_files.json")
    }()

    /// Текущий активный делегат пикера. Удерживается здесь, потому что
    /// UIDocumentPickerViewController хранит делегат через weak reference.
    private var activeDelegate: PickerDelegate?

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // ────────────────────────────────────────────────────────────────────────
    // Public API
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Презентует системный пикер `UIDocumentPickerViewController`.
     * `mimeTypes` пустой → разрешает все типы (`UTType.data`).
     *
     * Вызывать из main-thread.
     */
    func present(
        from presenter: UIViewController,
        mimeTypes: [String],
        multiple: Bool,
        completion: @escaping ([URL]?) -> Void
    ) {
        let utTypes = Self.resolveUTTypes(from: mimeTypes)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: utTypes, asCopy: false)
        picker.allowsMultipleSelection = multiple
        picker.shouldShowFileExtensions = true

        let delegate = PickerDelegate { [weak self] urls in
            self?.activeDelegate = nil
            completion(urls)
        }
        self.activeDelegate = delegate
        picker.delegate = delegate

        presenter.present(picker, animated: true)
    }

    /**
     * Создаёт bookmark для каждого URL, читает метаданные, сохраняет в JSON.
     * Возвращает массив словарей готовых к отдаче в Capacitor.
     */
    func persist(urls: [URL], completion: @escaping ([[String: Any]]) -> Void) {
        queue.async {
            var entries = self.readAll()
            var output: [[String: Any]] = []
            let now = Self.isoFormatter.string(from: Date())

            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

                guard let bookmarkData = try? url.bookmarkData(
                    options: [.minimalBookmark],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) else {
                    continue
                }

                let meta = self.readMetadata(url: url)
                let existing = entries.first(where: { $0.uri == url.absoluteString })
                let id = existing?.id ?? UUID().uuidString
                let pickedAt = existing?.pickedAt ?? now

                let entry = RecentEntry(
                    id: id,
                    uri: url.absoluteString,
                    bookmarkBase64: bookmarkData.base64EncodedString(),
                    fileName: meta.fileName,
                    mimeType: meta.mimeType,
                    fileSize: meta.fileSize,
                    pickedAt: pickedAt,
                    lastAccessedAt: now
                )
                entries.removeAll(where: { $0.id == id })
                entries.append(entry)
                output.append(entry.toDictionary())
            }

            self.writeAll(entries)
            completion(output)
        }
    }

    /**
     * Возвращает страницу «недавних» с фильтром по MIME.
     * Записи, для которых bookmark больше не резолвится, **молча выбрасываются**.
     */
    func list(
        limit: Int,
        offset: Int,
        mimeFilters: [String],
        completion: @escaping ([String: Any]) -> Void
    ) {
        queue.async {
            let all = self.readAll()
            var alive: [RecentEntry] = []
            var changed = false

            for entry in all {
                if let resolved = self.resolveBookmark(entry: entry) {
                    if resolved.bookmarkBase64 != entry.bookmarkBase64 { changed = true }
                    alive.append(resolved)
                } else {
                    changed = true
                }
            }

            if changed { self.writeAll(alive) }

            let filtered: [RecentEntry]
            if mimeFilters.isEmpty {
                filtered = alive
            } else {
                filtered = alive.filter { entry in
                    mimeFilters.contains(where: { Self.matchesMime(entry.mimeType, pattern: $0) })
                }
            }

            let sorted = filtered.sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            let total = sorted.count
            let end = min(offset + limit, total)
            let page = (offset < total) ? Array(sorted[offset..<end]) : []

            completion([
                "files": page.map { $0.toDictionary() },
                "total": total,
                "hasMore": offset + limit < total
            ])
        }
    }

    /**
     * Резолвит конкретную запись, обновляет lastAccessedAt.
     * Возвращает nil, если запись больше недоступна.
     */
    func resolve(id: String, completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            var all = self.readAll()
            guard let idx = all.firstIndex(where: { $0.id == id }) else {
                completion(nil); return
            }
            guard var resolved = self.resolveBookmark(entry: all[idx]) else {
                all.remove(at: idx)
                self.writeAll(all)
                completion(nil); return
            }
            resolved.lastAccessedAt = Self.isoFormatter.string(from: Date())
            all[idx] = resolved
            self.writeAll(all)
            completion(resolved.toDictionary())
        }
    }

    func remove(id: String, completion: @escaping () -> Void) {
        queue.async {
            var all = self.readAll()
            all.removeAll(where: { $0.id == id })
            self.writeAll(all)
            completion()
        }
    }

    func clear(completion: @escaping () -> Void) {
        queue.async {
            self.writeAll([])
            completion()
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Bookmark resolution
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Декодирует bookmark, проверяет isStale и при необходимости пересоздаёт его.
     */
    private func resolveBookmark(entry: RecentEntry) -> RecentEntry? {
        guard let data = Data(base64Encoded: entry.bookmarkBase64) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var bookmarkBase64 = entry.bookmarkBase64
        if isStale {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarkBase64 = refreshed.base64EncodedString()
            } else {
                return nil
            }
        }

        return RecentEntry(
            id: entry.id,
            uri: url.absoluteString,
            bookmarkBase64: bookmarkBase64,
            fileName: entry.fileName,
            mimeType: entry.mimeType,
            fileSize: entry.fileSize,
            pickedAt: entry.pickedAt,
            lastAccessedAt: entry.lastAccessedAt
        )
    }

    // ────────────────────────────────────────────────────────────────────────
    // Metadata
    // ────────────────────────────────────────────────────────────────────────

    private struct FileMetadata {
        let fileName: String
        let mimeType: String
        let fileSize: Int64
    }

    private func readMetadata(url: URL) -> FileMetadata {
        let name = url.lastPathComponent
        var size: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let s = attrs[.size] as? NSNumber {
            size = s.int64Value
        }
        let mime: String
        if #available(iOS 14.0, *) {
            mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        } else {
            mime = "application/octet-stream"
        }
        return FileMetadata(fileName: name, mimeType: mime, fileSize: size)
    }

    private static func resolveUTTypes(from mimeTypes: [String]) -> [UTType] {
        if mimeTypes.isEmpty { return [.data] }
        let mapped: [UTType] = mimeTypes.compactMap { mime in
            if mime == "*/*" { return UTType.data }
            // Поддерживаем wildcards вида `image/*` → image
            if mime.hasSuffix("/*") {
                let prefix = String(mime.dropLast(2))
                switch prefix {
                case "image": return .image
                case "video": return .movie
                case "audio": return .audio
                case "text":  return .text
                default:      return .data
                }
            }
            return UTType(mimeType: mime)
        }
        return mapped.isEmpty ? [.data] : mapped
    }

    private static func matchesMime(_ mime: String, pattern: String) -> Bool {
        if pattern == "*/*" { return true }
        if pattern.hasSuffix("/*") {
            let prefix = String(pattern.dropLast(2))
            return mime.lowercased().hasPrefix("\(prefix)/")
        }
        return mime.caseInsensitiveCompare(pattern) == .orderedSame
    }

    // ────────────────────────────────────────────────────────────────────────
    // JSON store
    // ────────────────────────────────────────────────────────────────────────

    private func readAll() -> [RecentEntry] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.compactMap { RecentEntry.fromJSON(dict: $0) }
    }

    private func writeAll(_ entries: [RecentEntry]) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let raw = entries.map { $0.toJSONDictionary() }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: []) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }
}

// MARK: - PickerDelegate

/**
 * Делегат пикера. Сохраняется в FilePicker.activeDelegate, чтобы не освободиться
 * до возврата управления пользователя из системного UI.
 */
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]?) -> Void

    init(completion: @escaping ([URL]?) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion([])
    }
}

// MARK: - RecentEntry

private struct RecentEntry {
    let id: String
    let uri: String
    let bookmarkBase64: String
    let fileName: String
    let mimeType: String
    let fileSize: Int64
    let pickedAt: String
    var lastAccessedAt: String

    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "uri": uri,
            "webPath": Self.convertToCapacitorPath(uri: uri),
            "fileName": fileName,
            "mimeType": mimeType,
            "fileSize": fileSize,
            "pickedAt": pickedAt,
            "lastAccessedAt": lastAccessedAt
        ]
    }

    func toJSONDictionary() -> [String: Any] {
        return [
            "id": id,
            "uri": uri,
            "bookmark": bookmarkBase64,
            "fileName": fileName,
            "mimeType": mimeType,
            "fileSize": fileSize,
            "pickedAt": pickedAt,
            "lastAccessedAt": lastAccessedAt
        ]
    }

    static func fromJSON(dict: [String: Any]) -> RecentEntry? {
        guard let id = dict["id"] as? String,
              let uri = dict["uri"] as? String,
              let bookmark = dict["bookmark"] as? String else { return nil }
        return RecentEntry(
            id: id,
            uri: uri,
            bookmarkBase64: bookmark,
            fileName: dict["fileName"] as? String ?? "",
            mimeType: dict["mimeType"] as? String ?? "application/octet-stream",
            fileSize: (dict["fileSize"] as? NSNumber)?.int64Value ?? 0,
            pickedAt: dict["pickedAt"] as? String ?? "",
            lastAccessedAt: dict["lastAccessedAt"] as? String ?? ""
        )
    }

    /// `file:///private/var/...` → `capacitor://localhost/_capacitor_file_/private/var/...`
    private static func convertToCapacitorPath(uri: String) -> String {
        guard let url = URL(string: uri) else { return uri }
        if url.isFileURL {
            return "capacitor://localhost/_capacitor_file_" + url.path
        }
        return uri
    }
}
