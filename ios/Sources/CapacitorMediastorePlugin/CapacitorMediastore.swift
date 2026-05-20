import Foundation
import Photos
import MediaPlayer
import UIKit

/**
 * CapacitorMediastore — бизнес-логика iOS-плагина.
 *
 * Источники данных:
 *  - Photos framework (`PHAsset`, `PHAssetCollection`) — фото и видео.
 *  - MediaPlayer (`MPMediaQuery`, `MPMediaItem`) — аудио / музыка из системной
 *    музыкальной библиотеки. Требует `NSAppleMusicUsageDescription` в Info.plist.
 *
 * Все тяжёлые операции вызываются с background-очередей через bridge-плагин.
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
                var coverThumbnailWebPath: String? = nil
                let innerGroup = DispatchGroup()
                var coverWebPath: String? = nil

                if let firstAsset = assets.firstObject {
                    coverUri = "ph://\(firstAsset.localIdentifier)"
                    innerGroup.enter()
                    self.resolveWebPath(for: firstAsset) { path in
                        coverWebPath = path
                        innerGroup.leave()
                    }
                    coverThumbnailWebPath = self.getOrCreateThumbnailFile(asset: firstAsset, targetSize: thumbSize)
                }
                innerGroup.wait()

                let album: [String: Any] = [
                    "id": collection.localIdentifier,
                    "title": collection.localizedTitle ?? "Untitled",
                    "count": assetCount,
                    "coverUri": coverUri ?? NSNull(),
                    "coverWebPath": coverWebPath ?? NSNull(),
                    "coverThumbnailWebPath": coverThumbnailWebPath ?? NSNull()
                ]

                lock.lock(); albums[i] = album; lock.unlock()
                group.leave()
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

    // MARK: - Media

    @objc public func getMedia(
        albumId: String?,
        limit: Int,
        offset: Int,
        type: String,
        completion: @escaping ([String: Any]) -> Void
    ) {
        if type == "audio" {
            getAudio(limit: limit, offset: offset, completion: completion)
            return
        }
        getPhotosVideos(albumId: albumId, limit: limit, offset: offset, type: type, completion: completion)
    }

    /**
     * Photo/Video через Photos framework.
     */
    private func getPhotosVideos(
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
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        }

        let fetchResult: PHFetchResult<PHAsset>
        if let albumId = albumId, !albumId.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
            if let collection = collections.firstObject {
                fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            } else {
                completion(["media": [], "total": 0, "hasMore": false]); return
            }
        } else {
            fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        }

        let total = fetchResult.count
        let safeOffset = min(offset, total)
        let safeLimit = min(limit, total - safeOffset)
        let hasMore = safeOffset + safeLimit < total

        guard safeLimit > 0 else {
            completion(["media": [], "total": total, "hasMore": hasMore]); return
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
                self.resolveWebPath(for: asset) { webPath in
                    item["webPath"] = webPath ?? NSNull()
                    lock.lock(); items[index] = item; lock.unlock()
                    group.leave()
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            var sortedItems: [[String: Any]] = []
            for i in 0..<safeLimit {
                lock.lock(); let item = items[i]; lock.unlock()
                if let it = item { sortedItems.append(it) }
            }
            completion(["media": sortedItems, "total": total, "hasMore": hasMore])
        }
    }

    /**
     * Audio через MPMediaQuery. Возвращает песни из системной библиотеки,
     * отсортированные по дате добавления (`dateAdded`). Tracks из облака
     * (Apple Music без локального файла) включаются с пустым `webPath`.
     */
    private func getAudio(
        limit: Int,
        offset: Int,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let query = MPMediaQuery.songs()
        guard let items = query.items, !items.isEmpty else {
            completion(["media": [], "total": 0, "hasMore": false]); return
        }
        // dateAdded доступен с iOS 10+ — сортируем DESC.
        let sorted = items.sorted { (a, b) -> Bool in
            return a.dateAdded > b.dateAdded
        }

        let total = sorted.count
        let safeOffset = min(offset, total)
        let safeLimit = min(limit, total - safeOffset)
        let hasMore = safeOffset + safeLimit < total

        guard safeLimit > 0 else {
            completion(["media": [], "total": total, "hasMore": hasMore]); return
        }

        let slice = Array(sorted[safeOffset..<(safeOffset + safeLimit)])
        let media = slice.map { audioItemToDictionary($0) }
        completion(["media": media, "total": total, "hasMore": hasMore])
    }

    // ────────────────────────────────────────────────────────────────────────
    // Thumbnails (Lazy Load)
    // ────────────────────────────────────────────────────────────────────────

    @objc public func getThumbnail(
        id: String,
        returnBase64: Bool,
        size: Int,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let dim = size > 0 ? size : Self.defaultThumbSize
        let targetSize = CGSize(width: dim, height: dim)

        // Сначала пробуем как photo/video.
        let photoFetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        if let asset = photoFetch.firstObject {
            let webPath = self.getOrCreateThumbnailFile(asset: asset, targetSize: targetSize) ?? ""
            let b64 = (returnBase64 && !webPath.isEmpty)
                ? self.readCachedAsBase64DataUrl(localIdentifier: asset.localIdentifier, size: dim) : ""
            completion(["webPath": webPath, "base64String": b64])
            return
        }

        // Если не нашли — пробуем как audio (id = persistentID в виде строки).
        if let audioItem = audioItemByPersistentId(id) {
            let webPath = self.getOrCreateAudioArtworkFile(item: audioItem, targetSize: targetSize) ?? ""
            let b64 = (returnBase64 && !webPath.isEmpty)
                ? self.readCachedAsBase64DataUrl(rawId: "audio_\(id)", size: dim) : ""
            completion(["webPath": webPath, "base64String": b64])
            return
        }

        completion(["webPath": "", "base64String": ""])
    }

    @objc public func getThumbnails(
        ids: [String],
        size: Int,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let dim = size > 0 ? size : Self.defaultThumbSize
        let targetSize = CGSize(width: dim, height: dim)

        // Разделяем ID на photo/video и audio.
        var phIds: [String] = []
        var audioIds: [String] = []

        let photoFetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var phAssetsById: [String: PHAsset] = [:]
        photoFetch.enumerateObjects { asset, _, _ in
            phAssetsById[asset.localIdentifier] = asset
        }
        for id in ids {
            if phAssetsById[id] != nil { phIds.append(id) } else { audioIds.append(id) }
        }

        let toCache: [PHAsset] = phIds.compactMap { phAssetsById[$0] }
        if !toCache.isEmpty {
            cachingImageManager.startCachingImages(for: toCache, targetSize: targetSize, contentMode: .aspectFill, options: nil)
        }

        let workQueue = DispatchQueue(label: "com.sangulov.plugins.mediastore.thumbnails", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: 6)
        let group = DispatchGroup()
        let lock = NSLock()
        var thumbs: [String: String] = [:]

        for rawId in phIds {
            guard let asset = phAssetsById[rawId] else { continue }
            group.enter()
            workQueue.async {
                semaphore.wait()
                let path = self.getOrCreateThumbnailFile(asset: asset, targetSize: targetSize)
                if let p = path, !p.isEmpty {
                    lock.lock(); thumbs[rawId] = p; lock.unlock()
                }
                semaphore.signal()
                group.leave()
            }
        }

        for rawId in audioIds {
            group.enter()
            workQueue.async {
                semaphore.wait()
                if let item = self.audioItemByPersistentId(rawId) {
                    let path = self.getOrCreateAudioArtworkFile(item: item, targetSize: targetSize)
                    if let p = path, !p.isEmpty {
                        lock.lock(); thumbs[rawId] = p; lock.unlock()
                    }
                }
                semaphore.signal()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            if !toCache.isEmpty {
                self.cachingImageManager.stopCachingImages(
                    for: toCache, targetSize: targetSize, contentMode: .aspectFill, options: nil
                )
            }
            completion(["thumbnails": thumbs])
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Helpers
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

    /**
     * Сохраняет обложку аудио на диск; возвращает webPath или nil, если обложки нет.
     */
    private func getOrCreateAudioArtworkFile(item: MPMediaItem, targetSize: CGSize) -> String? {
        let safeId = "audio_\(item.persistentID)"
        let dim = Int(targetSize.width)
        let fileURL = thumbDir.appendingPathComponent("thumb_\(safeId)_\(dim).jpg")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return "capacitor://localhost/_capacitor_file_" + fileURL.path
        }

        guard let image = item.artwork?.image(at: targetSize),
              let data = image.jpegData(compressionQuality: 0.7) else {
            return nil
        }
        do {
            try data.write(to: fileURL)
            return "capacitor://localhost/_capacitor_file_" + fileURL.path
        } catch {
            return nil
        }
    }

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
            for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if deliveredFinal { return }
            if isDegraded { return }
            deliveredFinal = true
            if let img = image, let data = img.jpegData(compressionQuality: 0.7) {
                do {
                    try data.write(to: fileURL)
                    resultPath = "capacitor://localhost/_capacitor_file_" + fileURL.path
                } catch { }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5.0)
        return resultPath
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

    private func resolveWebPath(for asset: PHAsset, completion: @escaping (String?) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        asset.requestContentEditingInput(with: options) { input, _ in
            guard let url = input?.fullSizeImageURL else {
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
        return "capacitor://localhost/_capacitor_file_" + url.path
    }

    /**
     * Конвертирует UTI (Uniform Type Identifier) либо расширение файла в MIME-тип.
     */
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
            if let t = UniformTypeIdentifiers.UTType(filenameExtension: utiOrExt),
               let m = t.preferredMIMEType {
                return m
            }
        }
        return "application/octet-stream"
    }
}
