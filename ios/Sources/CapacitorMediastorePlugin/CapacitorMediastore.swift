import Foundation
import Photos
import UIKit

/**
 * MediaGallery — бизнес-логика доступа к фото/видео галерее на iOS.
 *
 * Использует фреймворк Photos (PHAsset, PHAssetCollection, PHImageManager).
 * Все тяжёлые методы вызываются из `DispatchQueue.global(qos: .userInitiated)`
 * через bridge-плагин — на этой очереди и работают.
 */
@objc public class CapacitorMediastore: NSObject {

    /** Один экземпляр кеширующего менеджера на класс — заметно быстрее, чем создавать на каждый вызов. */
    private let cachingImageManager = PHCachingImageManager()

    /** Базовый размер квадратной миниатюры по умолчанию. */
    private static let defaultThumbSize: Int = 256

    /** Папка для кешированных миниатюр — Caches/, чтобы система могла удалять при нехватке места. */
    private lazy var thumbDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("mediastore_thumbs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    // MARK: - Permissions

    @objc public func checkPermissions() -> [String: String] {
        let status: PHAuthorizationStatus
        if #available(iOS 14, *) {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }
        return permissionResult(from: status)
    }

    @objc public func requestPermissions(completion: @escaping ([String: String]) -> Void) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                completion(self.permissionResult(from: status))
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                completion(self.permissionResult(from: status))
            }
        }
    }

    private func permissionResult(from status: PHAuthorizationStatus) -> [String: String] {
        let str: String
        switch status {
        case .authorized:
            str = "granted"
        case .limited:
            str = "limited"
        case .denied, .restricted:
            str = "denied"
        case .notDetermined:
            str = "prompt"
        @unknown default:
            str = "prompt"
        }
        return ["photos": str, "videos": str]
    }

    // MARK: - Albums

    /**
     * Возвращает список альбомов с подсчётом и обложкой.
     */
    @objc public func getAlbums(completion: @escaping ([[String: Any]]) -> Void) {
        let group = DispatchGroup()
        var allAlbums: [[String: Any]] = []
        let queue = DispatchQueue(label: "com.sangulov.plugins.mediastore.albums", attributes: .concurrent)

        // Смарт-альбомы
        group.enter()
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        self.collectAlbums(from: smartAlbums) { albums in
            queue.async(flags: .barrier) {
                allAlbums.append(contentsOf: albums)
            }
            group.leave()
        }

        // Пользовательские альбомы
        group.enter()
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        self.collectAlbums(from: userAlbums) { albums in
            queue.async(flags: .barrier) {
                allAlbums.append(contentsOf: albums)
            }
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            completion(allAlbums)
        }
    }

    /**
     * Проходит по результатам fetch и возвращает альбомы с ненулевым количеством (асинхронно).
     */
    private func collectAlbums(
        from fetchResult: PHFetchResult<PHAssetCollection>,
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let count = fetchResult.count
        guard count > 0 else {
            completion([])
            return
        }

        var albums: [Int: [String: Any]] = [:]
        let lock = NSLock()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.sangulov.plugins.mediastore.collect", attributes: .concurrent)

        let thumbSize = CGSize(width: Self.defaultThumbSize, height: Self.defaultThumbSize)

        for i in 0..<count {
            let collection = fetchResult.object(at: i)
            group.enter()

            queue.async {
                let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
                let assetCount = assets.count
                guard assetCount > 0 else {
                    group.leave()
                    return
                }

                var coverUri: String? = nil
                var coverThumbnailWebPath: String? = nil

                let innerGroup = DispatchGroup()
                var coverWebPath: String? = nil

                if let firstAsset = assets.firstObject {
                    coverUri = "ph://\(firstAsset.localIdentifier)"

                    // Резолвим webPath (оригинал) — асинхронно, ждём через innerGroup.
                    innerGroup.enter()
                    self.resolveWebPath(for: firstAsset) { path in
                        coverWebPath = path
                        innerGroup.leave()
                    }

                    // Резолвим thumbnail (синхронно внутри функции через семафор) — file URL, не base64.
                    coverThumbnailWebPath = self.getOrCreateThumbnailFile(
                        asset: firstAsset,
                        targetSize: thumbSize
                    )
                }

                innerGroup.wait() // Ждем резолва оригинального пути

                let album: [String: Any] = [
                    "id": collection.localIdentifier,
                    "title": collection.localizedTitle ?? "Untitled",
                    "count": assetCount,
                    "coverUri": coverUri ?? NSNull(),
                    "coverWebPath": coverWebPath ?? NSNull(),
                    "coverThumbnailWebPath": coverThumbnailWebPath ?? NSNull()
                ]

                lock.lock()
                albums[i] = album
                lock.unlock()

                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
             // Собираем результаты в порядке исходного fetchResult
             var result: [[String: Any]] = []
             for i in 0..<count {
                 lock.lock()
                 let album = albums[i]
                 lock.unlock()

                 if let a = album {
                     result.append(a)
                 }
             }
             completion(result)
        }
    }

    // MARK: - Media

    /**
     * Возвращает медиафайлы с метаданными и путями.
     */
    @objc public func getMedia(
        albumId: String?,
        limit: Int,
        offset: Int,
        type: String,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        switch type {
        case "photo":
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case "video":
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        default:
            fetchOptions.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        }

        let fetchResult: PHFetchResult<PHAsset>
        if let albumId = albumId, !albumId.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumId],
                options: nil
            )
            if let collection = collections.firstObject {
                fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            } else {
                completion(["media": [], "total": 0, "hasMore": false])
                return
            }
        } else {
            fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        }

        let total = fetchResult.count
        let safeOffset = min(offset, total)
        let safeLimit = min(limit, total - safeOffset)
        let hasMore = safeOffset + safeLimit < total

        guard safeLimit > 0 else {
            completion(["media": [], "total": total, "hasMore": hasMore])
            return
        }

        var items: [Int: [String: Any]] = [:]
        let lock = NSLock()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.sangulov.plugins.mediastore.processing", attributes: .concurrent)

        let range = safeOffset..<(safeOffset + safeLimit)

        for i in range {
            guard i < fetchResult.count else { break }
            let asset = fetchResult.object(at: i)
            let index = i - safeOffset

            group.enter()

            queue.async {
                var item = self.assetToItem(asset: asset)

                // Получение webPath (асинхронно)
                self.resolveWebPath(for: asset) { webPath in
                    item["webPath"] = webPath ?? NSNull()

                    lock.lock()
                    items[index] = item
                    lock.unlock()

                    group.leave()
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            var sortedItems: [[String: Any]] = []
            for i in 0..<safeLimit {
                lock.lock()
                let item = items[i]
                lock.unlock()

                if let it = item {
                    sortedItems.append(it)
                }
            }
            completion(["media": sortedItems, "total": total, "hasMore": hasMore])
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Thumbnails (Lazy Load)
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Lazy load thumbnail: возвращает webPath (file URL) и опционально base64.
     */
    @objc public func getThumbnail(
        id: String,
        returnBase64: Bool,
        size: Int,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else {
            completion(["webPath": "", "base64String": ""])
            return
        }

        let dim = size > 0 ? size : Self.defaultThumbSize
        let targetSize = CGSize(width: dim, height: dim)

        let webPath = self.getOrCreateThumbnailFile(asset: asset, targetSize: targetSize) ?? ""
        let b64 = (returnBase64 && !webPath.isEmpty)
            ? self.readCachedAsBase64DataUrl(asset: asset, size: dim)
            : ""

        completion(["webPath": webPath, "base64String": b64])
    }

    /**
     * Пакетная генерация миниатюр. Один нативный вызов = N миниатюр,
     * что устраняет overhead на JS-мост.
     */
    @objc public func getThumbnails(
        ids: [String],
        size: Int,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let dim = size > 0 ? size : Self.defaultThumbSize
        let targetSize = CGSize(width: dim, height: dim)

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        if fetch.count == 0 {
            completion(["thumbnails": [String: String]()])
            return
        }

        // Собираем ассеты по id, чтобы порядок ответа совпадал с входным `ids`.
        var assetsById: [String: PHAsset] = [:]
        fetch.enumerateObjects { asset, _, _ in
            assetsById[asset.localIdentifier] = asset
        }

        // Прогреваем кеш PHCachingImageManager — даёт быстрый decode на последующих requestImage.
        let toCache: [PHAsset] = ids.compactMap { assetsById[$0] }
        if !toCache.isEmpty {
            cachingImageManager.startCachingImages(
                for: toCache,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: nil
            )
        }

        // Ограничиваем параллелизм, чтобы не перегружать I/O.
        let workQueue = DispatchQueue(
            label: "com.sangulov.plugins.mediastore.thumbnails",
            attributes: .concurrent
        )
        let semaphore = DispatchSemaphore(value: 6)
        let group = DispatchGroup()
        let lock = NSLock()
        var thumbs: [String: String] = [:]

        for rawId in ids {
            guard let asset = assetsById[rawId] else { continue }
            group.enter()
            workQueue.async {
                semaphore.wait()
                let path = self.getOrCreateThumbnailFile(asset: asset, targetSize: targetSize)
                if let p = path, !p.isEmpty {
                    lock.lock()
                    thumbs[rawId] = p
                    lock.unlock()
                }
                semaphore.signal()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            if !toCache.isEmpty {
                self.cachingImageManager.stopCachingImages(
                    for: toCache,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: nil
                )
            }
            completion(["thumbnails": thumbs])
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Helpers Implementation
    // ────────────────────────────────────────────────────────────────────────

    private func assetToItem(asset: PHAsset) -> [String: Any] {
        let mediaType: String = asset.mediaType == .video ? "video" : "photo"
        let uri = "ph://\(asset.localIdentifier)"

        let createdAt: String
        if let date = asset.creationDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = formatter.string(from: date)
        } else {
            createdAt = ""
        }

        var fileName = ""
        var fileSize: Int64 = 0
        var mimeType = mediaType == "video" ? "video/mp4" : "image/jpeg"

        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first {
            fileName = resource.originalFilename
            if let sizeValue = resource.value(forKey: "fileSize") as? Int64 {
                fileSize = sizeValue
            }
            mimeType = self.mimeTypeFromUTI(resource.uniformTypeIdentifier)
        }

        return [
            "id": asset.localIdentifier,
            "type": mediaType,
            "uri": uri,
            "thumbnailUri": NSNull(),
            "thumbnailWebPath": NSNull(),
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "createdAt": createdAt,
            "duration": asset.duration,
            "mimeType": mimeType,
            "fileSize": fileSize,
            "fileName": fileName
        ]
    }

    /**
     * Возвращает webPath к закешированному файлу миниатюры (или nil).
     * Имена файлов sanitized по `[^A-Za-z0-9]` и включают `size`, чтобы хранить разные размеры параллельно.
     */
    private func getOrCreateThumbnailFile(asset: PHAsset, targetSize: CGSize) -> String? {
        let safeId = asset.localIdentifier
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        let dim = Int(targetSize.width)
        let fileURL = thumbDir.appendingPathComponent("thumb_\(safeId)_\(dim).jpg")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return "capacitor://localhost/_capacitor_file_" + fileURL.path
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        options.deliveryMode = .opportunistic

        let semaphore = DispatchSemaphore(value: 0)
        var resultPath: String? = nil
        var deliveredFinal = false

        cachingImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            // .opportunistic может прислать несколько callback'ов: degraded → final.
            // Берём ПОСЛЕДНИЙ (или единственный, если deliveryMode оказался mostly-fast).
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if deliveredFinal { return }
            if isDegraded {
                // skip и ждём финальный кадр
                return
            }
            deliveredFinal = true
            if let img = image, let data = img.jpegData(compressionQuality: 0.7) {
                do {
                    try data.write(to: fileURL)
                    resultPath = "capacitor://localhost/_capacitor_file_" + fileURL.path
                } catch {
                    // запись не удалась — оставляем nil
                }
            }
            semaphore.signal()
        }
        // Ждём финального кадра до 5 секунд (защита от iCloud-задержек).
        _ = semaphore.wait(timeout: .now() + 5.0)
        return resultPath
    }

    private func readCachedAsBase64DataUrl(asset: PHAsset, size: Int) -> String {
        let safeId = asset.localIdentifier
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        let fileURL = thumbDir.appendingPathComponent("thumb_\(safeId)_\(size).jpg")
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func resolveWebPath(for asset: PHAsset, completion: @escaping (String?) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true // разрешаем скачивание из iCloud

        asset.requestContentEditingInput(with: options) { input, _ in
            guard let url = input?.fullSizeImageURL else {
                // Для видео fallback
                if asset.mediaType == .video {
                   let videoOptions = PHVideoRequestOptions()
                   videoOptions.isNetworkAccessAllowed = true
                   PHImageManager.default().requestAVAsset(forVideo: asset, options: videoOptions) { avAsset, _, _ in
                       if let urlAsset = avAsset as? AVURLAsset {
                           completion(self.convertToCapacitorPath(url: urlAsset.url))
                       } else {
                           completion(nil)
                       }
                   }
                   return
                }
                completion(nil)
                return
            }
            completion(self.convertToCapacitorPath(url: url))
        }
    }

    private func convertToCapacitorPath(url: URL) -> String {
        // На iOS Capacitor использует bridge для конвертации file:// URL.
        // Стандартный формат: capacitor://localhost/_capacitor_file_ + path
        return "capacitor://localhost/_capacitor_file_" + url.path
    }

    // MARK: - Helpers

    /**
     * Конвертирует UTI (Uniform Type Identifier) в MIME-тип.
     */
    private func mimeTypeFromUTI(_ uti: String) -> String {
        let map: [String: String] = [
            "public.jpeg": "image/jpeg",
            "public.png": "image/png",
            "public.heic": "image/heic",
            "public.heif": "image/heif",
            "com.compuserve.gif": "image/gif",
            "public.tiff": "image/tiff",
            "com.adobe.raw-image": "image/x-adobe-dng",
            "public.mpeg-4": "video/mp4",
            "com.apple.quicktime-movie": "video/quicktime",
            "public.avi": "video/avi",
            "public.3gpp": "video/3gpp"
        ]
        return map[uti] ?? "application/octet-stream"
    }
}
