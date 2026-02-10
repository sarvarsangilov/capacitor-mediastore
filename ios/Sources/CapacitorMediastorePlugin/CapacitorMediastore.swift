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
    @objc public func getAlbums() -> [[String: Any]] {
        var albums: [[String: Any]] = []

        // Смарт-альбомы (Camera Roll, Favorites, Screenshots и т.д.)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        appendAlbums(from: smartAlbums, to: &albums)

        // Пользовательские альбомы
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        appendAlbums(from: userAlbums, to: &albums)

        return albums
    }

    /**
     * Проходит по результатам fetch и добавляет альбомы с ненулевым количеством.
     */
    private func appendAlbums(
        from fetchResult: PHFetchResult<PHAssetCollection>,
        to albums: inout [[String: Any]]
    ) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        fetchResult.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            let count = assets.count
            guard count > 0 else { return }

            var coverUri: Any = NSNull()
            if let firstAsset = assets.firstObject {
                coverUri = "ph://\(firstAsset.localIdentifier)"
            }

            let album: [String: Any] = [
                "id": collection.localIdentifier,
                "title": collection.localizedTitle ?? "Untitled",
                "count": count,
                "coverUri": coverUri
            ]
            albums.append(album)
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
    @objc public func getMedia(
        albumId: String?,
        limit: Int,
        offset: Int,
        type: String,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        // Фильтр по типу
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

        // Fetch
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

        let range = NSRange(location: safeOffset, length: safeLimit)
        let indexSet = IndexSet(integersIn: Range(range)!)
        var items: [[String: Any]] = []

        // Получаем миниатюры синхронно (targetSize маленький)
        let imageManager = PHCachingImageManager()
        let thumbOptions = PHImageRequestOptions()
        thumbOptions.isSynchronous = true
        thumbOptions.deliveryMode = .fastFormat
        thumbOptions.resizeMode = .fast
        let thumbSize = CGSize(width: 200, height: 200)

        fetchResult.enumerateObjects(at: indexSet, options: []) { asset, _, _ in
            let mediaType: String = asset.mediaType == .video ? "video" : "photo"
            let uri = "ph://\(asset.localIdentifier)"

            // ISO дата
            let createdAt: String
            if let date = asset.creationDate {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                createdAt = formatter.string(from: date)
            } else {
                createdAt = ""
            }

            // Миниатюра как base64
            var thumbnailBase64: Any = NSNull()
            imageManager.requestImage(
                for: asset,
                targetSize: thumbSize,
                contentMode: .aspectFill,
                options: thumbOptions
            ) { image, _ in
                if let img = image, let data = img.jpegData(compressionQuality: 0.6) {
                    thumbnailBase64 = "data:image/jpeg;base64,\(data.base64EncodedString())"
                }
            }

            // Получаем имя файла
            let fileName: String
            let resources = PHAssetResource.assetResources(for: asset)
            if let primaryResource = resources.first {
                fileName = primaryResource.originalFilename
            } else {
                fileName = ""
            }

            // Размер файла (может быть 0 если недоступен)
            var fileSize: Int64 = 0
            if let resource = resources.first {
                if let sizeValue = resource.value(forKey: "fileSize") as? Int64 {
                    fileSize = sizeValue
                }
            }

            // MIME
            let mimeType: String
            if let uti = resources.first?.uniformTypeIdentifier {
                mimeType = self.mimeTypeFromUTI(uti)
            } else {
                mimeType = mediaType == "video" ? "video/mp4" : "image/jpeg"
            }

            let item: [String: Any] = [
                "id": asset.localIdentifier,
                "type": mediaType,
                "uri": uri,
                "thumbnailUri": thumbnailBase64,
                "width": asset.pixelWidth,
                "height": asset.pixelHeight,
                "createdAt": createdAt,
                "duration": asset.duration,
                "mimeType": mimeType,
                "fileSize": fileSize,
                "fileName": fileName
            ]
            items.append(item)
        }

        completion(["media": items, "total": total, "hasMore": hasMore])
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
