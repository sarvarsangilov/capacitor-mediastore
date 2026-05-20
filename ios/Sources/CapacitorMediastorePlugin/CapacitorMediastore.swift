import Foundation
import Photos
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

/**
 * CapacitorMediastore — бизнес-логика iOS-плагина.
 *
 * Источники данных:
 *  - Photos framework (`PHAsset`, `PHAssetCollection`) — фото и видео.
 *  - MediaPlayer (`MPMediaQuery`, `MPMediaItem`) — аудио / музыка.
 *    Требует `NSAppleMusicUsageDescription` в Info.plist.
 *
 * Архитектурные принципы:
 *  - Никаких `DispatchSemaphore.wait()` — всё на completion handlers, чтобы
 *    не блокировать поток GCD и не получать starvation на медленном iCloud.
 *  - Cancellation через `PHImageManager.cancelImageRequest` для каждого
 *    in-flight requestID (см. [cancelPendingThumbnails]).
 *  - В `getMedia` НЕ резолвим тяжёлый webPath (это экспорт через
 *    `requestContentEditingInput` / `requestAVAsset`) — он берётся лениво
 *    через [resolveMediaPath] в момент открытия файла.
 */
@objc public class CapacitorMediastore: NSObject {

    private let cachingImageManager = PHCachingImageManager()

    private static let defaultThumbSize: Int = 256
    private static let thumbnailJPEGQuality: CGFloat = 0.75

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

    // ────────────────────────────────────────────────────────────────────────
    // Pending thumbnail requests — для отмены через cancelPendingThumbnails.
    // ────────────────────────────────────────────────────────────────────────

    private let pendingLock = NSLock()
    private var pendingRequestIDs = Set<PHImageRequestID>()
    private var cachedAssetIdsForPrefetch: [PHAsset] = []

    private func addPending(_ rid: PHImageRequestID) {
        pendingLock.lock(); pendingRequestIDs.insert(rid); pendingLock.unlock()
    }

    private func removePending(_ rid: PHImageRequestID) {
        pendingLock.lock(); pendingRequestIDs.remove(rid); pendingLock.unlock()
    }

    @objc public func cancelPendingThumbnails() {
        pendingLock.lock()
        let toCancel = pendingRequestIDs
        pendingRequestIDs.removeAll()
        let cached = cachedAssetIdsForPrefetch
        cachedAssetIdsForPrefetch = []
        pendingLock.unlock()

        for rid in toCancel {
            cachingImageManager.cancelImageRequest(rid)
        }
        if !cached.isEmpty {
            let size = CGSize(width: Self.defaultThumbSize, height: Self.defaultThumbSize)
            cachingImageManager.stopCachingImages(for: cached, targetSize: size, contentMode: .aspectFill, options: nil)
        }
    }

    // MARK: - Permissions

    @objc public func checkPermissions() -> [String: String] {
        let photoStatus: PHAuthorizationStatus
        if #available(iOS 14, *) {
            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            photoStatus = PHPhotoLibrary.authorizationStatus()
        }
        let photoStr = mapPhotoStatus(photoStatus)
        let audioStr = mapAudioStatus(MPMediaLibrary.authorizationStatus())
        return ["photos": photoStr, "videos": photoStr, "audio": audioStr]
    }

    @objc public func requestPermissions(completion: @escaping ([String: String]) -> Void) {
        let group = DispatchGroup()
        var photoStr = "denied"
        var audioStr = "denied"

        group.enter()
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                photoStr = self.mapPhotoStatus(status)
                group.leave()
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                photoStr = self.mapPhotoStatus(status)
                group.leave()
            }
        }

        group.enter()
        MPMediaLibrary.requestAuthorization { status in
            audioStr = self.mapAudioStatus(status)
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            completion(["photos": photoStr, "videos": photoStr, "audio": audioStr])
        }
    }

    private func mapPhotoStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .limited: return "limited"
        case .denied, .restricted: return "denied"
        case .notDetermined: return "prompt"
        @unknown default: return "prompt"
        }
    }

    private func mapAudioStatus(_ status: MPMediaLibraryAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied, .restricted: return "denied"
        case .notDetermined: return "prompt"
        @unknown default: return "prompt"
        }
    }

    // MARK: - hasMedia (cheap check)

    @objc public func hasMedia(type: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch type {
            case "audio":
                let q = MPMediaQuery.songs()
                completion((q.items?.count ?? 0) > 0)
            case "photo", "video", "all":
                let opts = PHFetchOptions()
                opts.fetchLimit = 1
                if type == "photo" {
                    opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                } else if type == "video" {
                    opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
                } else {
                    opts.predicate = NSPredicate(
                        format: "mediaType == %d OR mediaType == %d",
                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
                    )
                }
                let r = PHAsset.fetchAssets(with: opts)
                completion(r.count > 0)
            default:
                completion(false)
            }
        }
    }

    // MARK: - Albums

    @objc public func getAlbums(completion: @escaping ([[String: Any]]) -> Void) {
        let group = DispatchGroup()
        var allAlbums: [[String: Any]] = []
        let queue = DispatchQueue(label: "com.sangulov.plugins.mediastore.albums", attributes: .concurrent)

        group.enter()
        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        self.collectAlbums(from: smartAlbums) { albums in
            queue.async(flags: .barrier) { allAlbums.append(contentsOf: albums) }
            group.leave()
        }

        group.enter()
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        self.collectAlbums(from: userAlbums) { albums in
            queue.async(flags: .barrier) { allAlbums.append(contentsOf: albums) }
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            completion(allAlbums)
        }
    }

    private func collectAlbums(
        from fetchResult: PHFetchResult<PHAssetCollection>,
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let count = fetchResult.count
        guard count > 0 else { completion([]); return }

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
                guard assetCount > 0 else { group.leave(); return }

                var coverUri: String? = nil
                if let firstAsset = assets.firstObject {
                    coverUri = "ph://\(firstAsset.localIdentifier)"

                    // Резолвим coverThumbnailWebPath асинхронно.
                    self.getOrCreateThumbnailFile(asset: firstAsset, targetSize: thumbSize) { thumbPath in
                        let album: [String: Any] = [
                            "id": collection.localIdentifier,
                            "title": collection.localizedTitle ?? "Untitled",
                            "count": assetCount,
                            "coverUri": coverUri ?? NSNull(),
                            // Альбомы не резолвим cover на full size — это слишком дорого.
                            // UI получает coverThumbnailWebPath, этого достаточно для grid'а.
                            "coverWebPath": NSNull(),
                            "coverThumbnailWebPath": thumbPath ?? NSNull()
                        ]
                        lock.lock(); albums[i] = album; lock.unlock()
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            var result: [[String: Any]] = []
            for i in 0..<count {
                lock.lock(); let album = albums[i]; lock.unlock()
                if let a = album { result.append(a) }
            }
            completion(result)
        }
    }

    // MARK: - Media (offset + cursor pagination)

    @objc public func getMedia(
        albumId: String?,
        limit: Int,
        offset: Int,
        type: String,
        cursor: String?,
        completion: @escaping ([String: Any]) -> Void
    ) {
        if type == "audio" {
            getAudio(limit: limit, offset: offset, cursor: cursor, completion: completion)
            return
        }
        getPhotosVideos(
            albumId: albumId, limit: limit, offset: offset, type: type,
            cursor: cursor, completion: completion
        )
    }

    private func getPhotosVideos(
        albumId: String?,
        limit: Int,
        offset: Int,
        type: String,
        cursor: String?,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false),
            NSSortDescriptor(key: "localIdentifier", ascending: false)
        ]

        // Type predicate
        let typePred: NSPredicate
        switch type {
        case "photo":
            typePred = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case "video":
            typePred = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        default:
            typePred = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        }

        let cursorPos: CursorPosition? = (cursor?.isEmpty == false) ? Self.decodeCursor(cursor!) : nil
        var predicates: [NSPredicate] = [typePred]
        if let cur = cursorPos {
            predicates.append(NSPredicate(
                format: "creationDate < %@",
                Date(timeIntervalSince1970: cur.timestamp) as NSDate
            ))
        }
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        // Если есть cursor — limit'им на уровне fetchLimit. Иначе берём offset+limit.
        if cursorPos != nil {
            fetchOptions.fetchLimit = limit
        }

        let fetchResult: PHFetchResult<PHAsset>
        if let albumId = albumId, !albumId.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
            if let collection = collections.firstObject {
                fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            } else {
                completion(["media": [], "total": 0, "hasMore": false, "nextCursor": NSNull()]); return
            }
        } else {
            fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        }

        // For cursor mode total ≠ count (мы не считаем все элементы). Для UI достаточно
        // знать total один раз — отдадим count только в offset-режиме.
        let total: Int = (cursorPos != nil) ? -1 : fetchResult.count

        let safeOffset: Int
        let safeLimit: Int
        if cursorPos != nil {
            safeOffset = 0
            safeLimit = min(limit, fetchResult.count)
        } else {
            safeOffset = min(offset, fetchResult.count)
            safeLimit = min(limit, fetchResult.count - safeOffset)
        }

        guard safeLimit > 0 else {
            completion([
                "media": [],
                "total": total == -1 ? 0 : total,
                "hasMore": false,
                "nextCursor": NSNull()
            ])
            return
        }

        var items: [Int: [String: Any]] = [:]
        let range = safeOffset..<(safeOffset + safeLimit)

        for i in range {
            guard i < fetchResult.count else { break }
            let asset = fetchResult.object(at: i)
            let index = i - safeOffset
            // НЕ резолвим webPath здесь — это дорого. Клиент сам вызовет resolveMediaPath
            // когда юзер откроет файл.
            items[index] = assetToItem(asset: asset)
        }

        var sortedItems: [[String: Any]] = []
        for i in 0..<safeLimit {
            if let it = items[i] { sortedItems.append(it) }
        }

        // nextCursor + hasMore
        var nextCursor: String? = nil
        var hasMore: Bool
        if cursorPos != nil {
            // cursor-режим: nextCursor = creationDate последнего элемента.
            if let lastAsset = (safeOffset + safeLimit - 1 < fetchResult.count)
                ? fetchResult.object(at: safeOffset + safeLimit - 1) : nil,
                let lastDate = lastAsset.creationDate,
                sortedItems.count == limit {
                nextCursor = Self.encodeCursor(CursorPosition(timestamp: lastDate.timeIntervalSince1970))
                hasMore = true
            } else {
                hasMore = false
            }
        } else {
            hasMore = safeOffset + safeLimit < (total == -1 ? 0 : total)
            if hasMore {
                if let lastAsset = (safeOffset + safeLimit - 1 < fetchResult.count)
                    ? fetchResult.object(at: safeOffset + safeLimit - 1) : nil,
                    let lastDate = lastAsset.creationDate {
                    nextCursor = Self.encodeCursor(CursorPosition(timestamp: lastDate.timeIntervalSince1970))
                }
            }
        }

        completion([
            "media": sortedItems,
            "total": total == -1 ? 0 : total,
            "hasMore": hasMore,
            "nextCursor": nextCursor ?? NSNull()
        ])
    }

    /**
     * Audio через MPMediaQuery, отсортированное по dateAdded DESC.
     * Поддерживает cursor через timestamp dateAdded.
     */
    private func getAudio(
        limit: Int,
        offset: Int,
        cursor: String?,
        completion: @escaping ([String: Any]) -> Void
    ) {
        // Проверка авторизации — без неё MPMediaQuery.items вернёт nil.
        let auth = MPMediaLibrary.authorizationStatus()
        NSLog("[CapacitorMediastore] getAudio: auth=\(auth.rawValue), limit=\(limit), offset=\(offset), cursor=\(cursor != nil)")
        if auth != .authorized {
            NSLog("[CapacitorMediastore] getAudio: NOT authorized — call requestPermissions() first")
            completion(["media": [], "total": 0, "hasMore": false, "nextCursor": NSNull()]); return
        }

        let query = MPMediaQuery.songs()
        let allItems = query.items
        NSLog("[CapacitorMediastore] getAudio: MPMediaQuery.songs() returned \(allItems?.count ?? -1) items")
        guard var items = allItems, !items.isEmpty else {
            completion(["media": [], "total": 0, "hasMore": false, "nextCursor": NSNull()]); return
        }

        items.sort { a, b in a.dateAdded > b.dateAdded }

        let cursorPos = (cursor?.isEmpty == false) ? Self.decodeCursor(cursor!) : nil
        if let cur = cursorPos {
            let cutoff = Date(timeIntervalSince1970: cur.timestamp)
            items = items.filter { $0.dateAdded < cutoff }
        }

        let total = items.count
        let safeOffset = (cursorPos != nil) ? 0 : min(offset, total)
        let safeLimit = min(limit, total - safeOffset)

        guard safeLimit > 0 else {
            completion(["media": [], "total": total, "hasMore": false, "nextCursor": NSNull()]); return
        }

        let slice = Array(items[safeOffset..<(safeOffset + safeLimit)])
        let media = slice.map { audioItemToDictionary($0) }
        let hasMore = safeOffset + safeLimit < total

        var nextCursor: String? = nil
        if hasMore || cursorPos != nil, let lastItem = slice.last {
            nextCursor = Self.encodeCursor(CursorPosition(timestamp: lastItem.dateAdded.timeIntervalSince1970))
        }

        completion([
            "media": media,
            "total": total,
            "hasMore": hasMore,
            "nextCursor": nextCursor ?? NSNull()
        ])
    }

    // MARK: - Resolve full-size webPath (lazy)

    @objc public func resolveMediaPath(id: String, completion: @escaping ([String: Any]) -> Void) {
        // Сначала пробуем как photo/video.
        let photoFetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        if let asset = photoFetch.firstObject {
            resolveWebPath(for: asset) { webPath in
                completion([
                    "uri": "ph://\(asset.localIdentifier)",
                    "webPath": webPath ?? NSNull()
                ])
            }
            return
        }
        // Audio?
        if let audioItem = audioItemByPersistentId(id) {
            let uri = audioItem.assetURL?.absoluteString ?? ""
            let webPath: Any = audioItem.assetURL.flatMap {
                "capacitor://localhost/_capacitor_file_" + $0.path
            } ?? NSNull()
            completion(["uri": uri, "webPath": webPath])
            return
        }
        completion(["uri": "", "webPath": NSNull()])
    }

    // MARK: - Thumbnails (Lazy Load, async callbacks)

    @objc public func getThumbnail(
        id: String,
        returnBase64: Bool,
        size: Int,
        density: Double,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let dim = effectiveThumbDim(size: size, density: density)
        let targetSize = CGSize(width: dim, height: dim)

        let photoFetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        if let asset = photoFetch.firstObject {
            getOrCreateThumbnailFile(asset: asset, targetSize: targetSize) { [weak self] webPath in
                guard let self = self else { completion(["webPath": "", "base64String": ""]); return }
                let path = webPath ?? ""
                let b64 = (returnBase64 && !path.isEmpty)
                    ? self.readCachedAsBase64DataUrl(localIdentifier: asset.localIdentifier, size: dim) : ""
                completion(["webPath": path, "base64String": b64])
            }
            return
        }

        if let audioItem = audioItemByPersistentId(id) {
            let webPath = getOrCreateAudioArtworkFile(item: audioItem, targetSize: targetSize) ?? ""
            let b64 = (returnBase64 && !webPath.isEmpty)
                ? readCachedAsBase64DataUrl(rawId: "audio_\(id)", size: dim) : ""
            completion(["webPath": webPath, "base64String": b64])
            return
        }

        completion(["webPath": "", "base64String": ""])
    }

    @objc public func getThumbnails(
        ids: [String],
        size: Int,
        density: Double,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let dim = effectiveThumbDim(size: size, density: density)
        let targetSize = CGSize(width: dim, height: dim)

        let (phAssetsById, audioIds) = splitIdsByType(ids: ids)

        // Warmup caching manager for PHAssets.
        let toCache = phAssetsById.values.map { $0 }
        if !toCache.isEmpty {
            cachingImageManager.startCachingImages(
                for: Array(toCache), targetSize: targetSize, contentMode: .aspectFill, options: nil
            )
            pendingLock.lock()
            cachedAssetIdsForPrefetch.append(contentsOf: toCache)
            pendingLock.unlock()
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var thumbs: [String: String] = [:]

        for id in ids {
            if let asset = phAssetsById[id] {
                group.enter()
                getOrCreateThumbnailFile(asset: asset, targetSize: targetSize) { path in
                    if let p = path, !p.isEmpty {
                        lock.lock(); thumbs[id] = p; lock.unlock()
                    }
                    group.leave()
                }
            } else if audioIds.contains(id) {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    if let item = self.audioItemByPersistentId(id),
                       let path = self.getOrCreateAudioArtworkFile(item: item, targetSize: targetSize) {
                        lock.lock(); thumbs[id] = path; lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            // Cleanup caching scope.
            if !toCache.isEmpty {
                self.cachingImageManager.stopCachingImages(
                    for: Array(toCache), targetSize: targetSize, contentMode: .aspectFill, options: nil
                )
                self.pendingLock.lock()
                self.cachedAssetIdsForPrefetch.removeAll { a in toCache.contains(a) }
                self.pendingLock.unlock()
            }
            completion(["thumbnails": thumbs])
        }
    }

    @objc public func prefetchThumbnails(ids: [String], size: Int, density: Double) {
        let dim = effectiveThumbDim(size: size, density: density)
        let targetSize = CGSize(width: dim, height: dim)
        let (phAssetsById, audioIds) = splitIdsByType(ids: ids)

        let toCache = Array(phAssetsById.values)
        if !toCache.isEmpty {
            cachingImageManager.startCachingImages(
                for: toCache, targetSize: targetSize, contentMode: .aspectFill, options: nil
            )
            pendingLock.lock()
            cachedAssetIdsForPrefetch.append(contentsOf: toCache)
            pendingLock.unlock()
        }

        // Fire-and-forget background tasks для записи файлов на диск.
        for id in ids {
            if let asset = phAssetsById[id] {
                getOrCreateThumbnailFile(asset: asset, targetSize: targetSize) { _ in /* discard */ }
            } else if audioIds.contains(id) {
                DispatchQueue.global(qos: .utility).async {
                    if let item = self.audioItemByPersistentId(id) {
                        _ = self.getOrCreateAudioArtworkFile(item: item, targetSize: targetSize)
                    }
                }
            }
        }
    }

    private func splitIdsByType(ids: [String]) -> (photo: [String: PHAsset], audio: Set<String>) {
        let photoFetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var phAssetsById: [String: PHAsset] = [:]
        photoFetch.enumerateObjects { asset, _, _ in
            phAssetsById[asset.localIdentifier] = asset
        }
        let audioIds = Set(ids.filter { phAssetsById[$0] == nil })
        return (phAssetsById, audioIds)
    }

    private func effectiveThumbDim(size: Int, density: Double) -> Int {
        let s = size > 0 ? size : Self.defaultThumbSize
        let d = density > 0 ? density : 1.0
        let eff = Int((Double(s) * d).rounded())
        return max(eff, 32)
    }

    // MARK: - Async thumbnail file generation

    /**
     * Async-вариант генерации миниатюры. Никаких semaphore.wait():
     *  - проверяет файловый кеш → возвращает мгновенно.
     *  - иначе шлёт requestImage с completion handler.
     *  - в completion пишет JPEG на диск, отдаёт callback.
     *
     * RequestID трекается в [pendingRequestIDs] для возможности отмены.
     */
    private func getOrCreateThumbnailFile(
        asset: PHAsset,
        targetSize: CGSize,
        completion: @escaping (String?) -> Void
    ) {
        let safeId = asset.localIdentifier
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        let dim = Int(targetSize.width)
        let fileURL = thumbDir.appendingPathComponent("thumb_\(safeId)_\(dim).jpg")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            completion("capacitor://localhost/_capacitor_file_" + fileURL.path)
            return
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        options.deliveryMode = .opportunistic

        var didDeliverFinal = false
        let requestID = cachingImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            guard let self = self else { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if isCancelled {
                completion(nil)
                return
            }
            if didDeliverFinal { return }
            if isDegraded { return } // ждём финальный кадр
            didDeliverFinal = true

            // requestID trackedID: на момент callback'а у нас уже есть Int32, но он
            // приходит как параметр первого вызова. Используем поле info или
            // переменную захвата ниже.

            if let img = image, let data = img.jpegData(compressionQuality: Self.thumbnailJPEGQuality) {
                do {
                    try data.write(to: fileURL)
                    completion("capacitor://localhost/_capacitor_file_" + fileURL.path)
                } catch {
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }
        addPending(requestID)
        // Снять с pending по завершению — нам не приходит явный сигнал, но
        // последующая отмена не повредит, а cancelImageRequest безопасен для завершённых ID.
        // Очистим через небольшой grace-период:
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.removePending(requestID)
        }
    }

    private func getOrCreateAudioArtworkFile(item: MPMediaItem, targetSize: CGSize) -> String? {
        let safeId = "audio_\(item.persistentID)"
        let dim = Int(targetSize.width)
        let fileURL = thumbDir.appendingPathComponent("thumb_\(safeId)_\(dim).jpg")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return "capacitor://localhost/_capacitor_file_" + fileURL.path
        }
        guard let image = item.artwork?.image(at: targetSize),
              let data = image.jpegData(compressionQuality: Self.thumbnailJPEGQuality) else {
            return nil
        }
        do {
            try data.write(to: fileURL)
            return "capacitor://localhost/_capacitor_file_" + fileURL.path
        } catch {
            return nil
        }
    }

    private func readCachedAsBase64DataUrl(localIdentifier: String, size: Int) -> String {
        let safeId = localIdentifier
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        return readCachedAsBase64DataUrl(rawId: safeId, size: size)
    }

    private func readCachedAsBase64DataUrl(rawId: String, size: Int) -> String {
        let fileURL = thumbDir.appendingPathComponent("thumb_\(rawId)_\(size).jpg")
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    // MARK: - Helpers

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
            mimeType = mimeTypeFromUTI(resource.uniformTypeIdentifier)
        }

        let isLive = asset.mediaSubtypes.contains(.photoLive)
        let isHDR = asset.mediaSubtypes.contains(.photoHDR)

        return [
            "id": asset.localIdentifier,
            "type": mediaType,
            "uri": uri,
            // webPath намеренно null — резолвится лениво через resolveMediaPath.
            "webPath": NSNull(),
            "thumbnailUri": NSNull(),
            "thumbnailWebPath": NSNull(),
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "orientation": 0, // PhotoKit возвращает уже-rotation-нормализованные размеры
            "isLivePhoto": isLive,
            "isHDR": isHDR,
            "createdAt": createdAt,
            "duration": asset.duration,
            "mimeType": mimeType,
            "fileSize": fileSize,
            "fileName": fileName
        ]
    }

    private func audioItemToDictionary(_ item: MPMediaItem) -> [String: Any] {
        let id = "\(item.persistentID)"
        let title = item.title ?? ""
        let artist = item.artist ?? ""
        let album = item.albumTitle ?? ""
        let duration = item.playbackDuration
        let assetURL = item.assetURL

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdAt = formatter.string(from: item.dateAdded)

        var uri = ""
        var webPath: Any = NSNull()
        var fileSize: Int64 = 0
        var mimeType = "audio/mpeg"
        var fileName = title.isEmpty ? "Untitled" : title

        if let url = assetURL {
            uri = url.absoluteString
            webPath = "capacitor://localhost/_capacitor_file_" + url.path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let s = attrs[.size] as? NSNumber {
                fileSize = s.int64Value
            }
            fileName = url.lastPathComponent
            mimeType = mimeTypeFromUTI(url.pathExtension)
        }

        return [
            "id": id,
            "type": "audio",
            "uri": uri,
            "webPath": webPath,
            "thumbnailUri": NSNull(),
            "thumbnailWebPath": NSNull(),
            "width": 0,
            "height": 0,
            "orientation": 0,
            "isLivePhoto": false,
            "isHDR": false,
            "createdAt": createdAt,
            "duration": duration,
            "mimeType": mimeType,
            "fileSize": fileSize,
            "fileName": fileName,
            "title": title,
            "artist": artist,
            "album": album
        ]
    }

    private func audioItemByPersistentId(_ id: String) -> MPMediaItem? {
        guard let persistentID = UInt64(id) else { return nil }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        ))
        return query.items?.first
    }

    private func resolveWebPath(for asset: PHAsset, completion: @escaping (String?) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        asset.requestContentEditingInput(with: options) { input, _ in
            if let url = input?.fullSizeImageURL {
                completion("capacitor://localhost/_capacitor_file_" + url.path)
                return
            }
            if asset.mediaType == .video {
                let videoOptions = PHVideoRequestOptions()
                videoOptions.isNetworkAccessAllowed = true
                PHImageManager.default().requestAVAsset(forVideo: asset, options: videoOptions) { avAsset, _, _ in
                    if let urlAsset = avAsset as? AVURLAsset {
                        completion("capacitor://localhost/_capacitor_file_" + urlAsset.url.path)
                    } else {
                        completion(nil)
                    }
                }
                return
            }
            completion(nil)
        }
    }

    private func mimeTypeFromUTI(_ utiOrExt: String) -> String {
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
            "public.3gpp": "video/3gpp",
            "public.mp3": "audio/mpeg",
            "com.apple.m4a-audio": "audio/mp4",
            "public.aac-audio": "audio/aac"
        ]
        if let m = map[utiOrExt] { return m }
        if #available(iOS 14.0, *) {
            if let t = UTType(filenameExtension: utiOrExt),
               let m = t.preferredMIMEType {
                return m
            }
            if let t = UTType(utiOrExt),
               let m = t.preferredMIMEType {
                return m
            }
        }
        return "application/octet-stream"
    }

    // MARK: - Cursor encoding

    private struct CursorPosition {
        let timestamp: TimeInterval
    }

    private static func encodeCursor(_ pos: CursorPosition) -> String {
        let raw = "\(pos.timestamp)"
        guard let data = raw.data(using: .utf8) else { return "" }
        return data.base64EncodedString()
    }

    private static func decodeCursor(_ token: String) -> CursorPosition? {
        guard let data = Data(base64Encoded: token),
              let raw = String(data: data, encoding: .utf8),
              let ts = TimeInterval(raw) else { return nil }
        return CursorPosition(timestamp: ts)
    }
}
