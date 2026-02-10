import Foundation
import Photos
import UIKit

/**
 * MediaGallery — бизнес-логика доступа к фото/видео галерее на iOS.
 *
 * Использует фреймворк Photos (PHAsset, PHAssetCollection, PHImageManager).
 */
@objc public class CapacitorMediastore: NSObject {

    // MARK: - Permissions

    /**
     * Возвращает текущий статус разрешений.
     */
    @objc public func checkPermissions() -> [String: String] {
        let status: PHAuthorizationStatus
        if #available(iOS 14, *) {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }
        return permissionResult(from: status)
    }

    /**
     * Запрашивает разрешение на доступ к медиагалерее.
     * Вызывает completion с результатом.
     */
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

    /**
     * Конвертирует PHAuthorizationStatus в словарь статусов для Capacitor.
     */
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

        group.notify(queue: .main) {
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

        var albums: [Int: [String: Any]] = [:]
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.sangulov.plugins.mediastore.collect", attributes: .concurrent)
        
        // Массив индексов, чтобы итерироваться
        let count = fetchResult.count
        guard count > 0 else {
            completion([])
            return
        }

        for i in 0..<count {
            let collection = fetchResult.object(at: i)
            group.enter()
            
            queue.async {
                let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
                let count = assets.count
                guard count > 0 else {
                    group.leave()
                    return
                }

                var coverUri: String? = nil
                var coverWebPath: String? = nil
                var coverThumbnailWebPath: String? = nil
                
                let innerGroup = DispatchGroup()
                
                if let firstAsset = assets.firstObject {
                    coverUri = "ph://\(firstAsset.localIdentifier)"
                    
                    // Резолвим webPath (оригинал)
                    innerGroup.enter()
                    self.resolveWebPath(for: firstAsset) { path in
                        coverWebPath = path
                        innerGroup.leave()
                    }
                    
                    // Резолвим thumbnail (синхронно, так как options.isSynchronous = true)
                    let imageManager = PHCachingImageManager()
                    let thumbOptions = PHImageRequestOptions()
                    thumbOptions.isSynchronous = true
                    thumbOptions.resizeMode = .fast
                    thumbOptions.deliveryMode = .fastFormat
                    let thumbSize = CGSize(width: 300, height: 300)
                    
                    coverThumbnailWebPath = self.getOrCreateThumbnailFile(
                        asset: firstAsset,
                        imageManager: imageManager,
                        options: thumbOptions,
                        targetSize: thumbSize
                    )
                }

                innerGroup.wait() // Ждем резолва оригинального пути
                
                let album: [String: Any] = [
                    "id": collection.localIdentifier,
                    "title": collection.localizedTitle ?? "Untitled",
                    "count": count,
                    "coverUri": coverUri ?? NSNull(),
                    "coverWebPath": coverWebPath ?? NSNull(),
                    "coverThumbnailWebPath": coverThumbnailWebPath ?? NSNull()
                ]
                
                queue.async(flags: .barrier) {
                    albums[i] = album
                }
                group.leave()
            }
        }
        
        group.notify(queue: .global(qos: .userInitiated)) {
             // Собираем результаты
             var result: [[String: Any]] = []
             for i in 0..<count {
                 if let album = albums[i] {
                     result.append(album)
                 }
             }
             completion(result)
        }
    }

    // MARK: - Media

    /**
     * Возвращает медиафайлы с метаданными, пагинацией и фильтрацией.
     *
     * - Parameters:
     *   - albumId: localIdentifier альбома. nil = все медиа.
     *   - limit: Максимальное количество элементов.
     *   - offset: Сдвиг для пагинации.
     *   - type: "photo", "video" или "all".
     *   - completion: Вызывается с результатом (основной поток не гарантирован).
     */
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

        var items: [Int: [String: Any]] = [:] // Dictionary for thread-safe writing by index
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.sangulov.plugins.mediastore.processing", attributes: .concurrent)

        let range = safeOffset..<(safeOffset + safeLimit)
        
        // Пре-феч миниатюр
        let imageManager = PHCachingImageManager()
        let thumbOptions = PHImageRequestOptions()
        thumbOptions.isSynchronous = true
        thumbOptions.deliveryMode = .fastFormat
        thumbOptions.resizeMode = .fast
        let thumbSize = CGSize(width: 200, height: 200)

        for i in range {
            guard i < fetchResult.count else { break }
            let asset = fetchResult.object(at: i)
            let index = i - safeOffset
            
            group.enter()
            
            // Базовая инфо и миниатюра (синхронно)
            var item = self.assetToItem(asset: asset, imageManager: imageManager, thumbOptions: thumbOptions, thumbSize: thumbSize)
            
            // Получение webPath (асинхронно)
            self.resolveWebPath(for: asset) { webPath in
                item["webPath"] = webPath
                queue.async(flags: .barrier) {
                    items[index] = item
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // Собираем массив в правильном порядке
            var sortedItems: [[String: Any]] = []
            for i in 0..<safeLimit {
                if let item = items[i] {
                    sortedItems.append(item)
                }
            }
            completion(["media": sortedItems, "total": total, "hasMore": hasMore])
        }
    }
    
    // ────────────────────────────────────────────────────────────────────────
    // Helpers Implementation
    // ────────────────────────────────────────────────────────────────────────

    private func assetToItem(
        asset: PHAsset,
        imageManager: PHImageManager,
        thumbOptions: PHImageRequestOptions,
        thumbSize: CGSize
    ) -> [String: Any] {
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

        // Вместо base64 сохраняем файл
        let thumbnailWebPath = self.getOrCreateThumbnailFile(asset: asset, imageManager: imageManager, options: thumbOptions, targetSize: thumbSize)

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
            "thumbnailUri": thumbnailWebPath ?? NSNull(), // Оставляем совместимость, но теперь это путь
            "thumbnailWebPath": thumbnailWebPath ?? NSNull(),
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
     * Генерирует или возвращает путь к миниатюре во временной папке.
     */
    private func getOrCreateThumbnailFile(
        asset: PHAsset,
        imageManager: PHImageManager,
        options: PHImageRequestOptions,
        targetSize: CGSize
    ) -> String? {
        // Очищаем ID от символов, недопустимых в именах файлов (например, слэшей)
        let safeId = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let filename = "thumb_\(safeId).jpg"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return "capacitor://localhost/_capacitor_file_" + fileURL.path
        }
        
        var resultPath: String? = nil
        
        // Синхронный запрос (options.isSynchronous = true)
        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            if let img = image, let data = img.jpegData(compressionQuality: 0.7) {
                do {
                    try data.write(to: fileURL)
                    resultPath = "capacitor://localhost/_capacitor_file_" + fileURL.path
                } catch {
                    print("Error saving thumbnail: \(error)")
                }
            }
        }
        
        return resultPath
    }
    
    private func resolveWebPath(for asset: PHAsset, completion: @escaping (String?) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true // разрешаем скачивание из iCloud

        asset.requestContentEditingInput(with: options) { input, info in
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
        // На iOS Capacitor использует bridge для конвертации file:// URL
        // Стандартный формат: capacitor://localhost/_capacitor_file_ + path
        // Также нужно убедиться, что файл доступен. PHContentEditingInput дает URL, к которому 
        // у приложения есть доступ на чтение.
        return "capacitor://localhost/_capacitor_file_" + url.path
    }

    // MARK: - Helpers

    /**
     * Конвертирует UTI (Uniform Type Identifier) в MIME-тип.
     */
    private func mimeTypeFromUTI(_ uti: String) -> String {
        // Основные маппинги
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
