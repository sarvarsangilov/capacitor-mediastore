import Foundation
import Capacitor
import Photos
import MediaPlayer
import UIKit

/**
 * CapacitorMediastorePlugin — Capacitor 8.x plugin для iOS.
 *
 * Слушатели изменений:
 *  - `PHPhotoLibraryChangeObserver` — фото / видео.
 *  - `MPMediaLibraryDidChange` Notification — аудио.
 *  Изменения отправляются в JS как `mediaLibraryChanged` с дебаунсом 500ms.
 */
@objc(CapacitorMediastorePlugin)
public class CapacitorMediastorePlugin: CAPPlugin, CAPBridgedPlugin, PHPhotoLibraryChangeObserver {

    public let identifier = "CapacitorMediastorePlugin"
    public let jsName = "CapacitorMediastore"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAlbums", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getMedia", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hasMedia", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveMediaPath", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getThumbnail", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getThumbnails", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "prefetchThumbnails", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelPendingThumbnails", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getRecentFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveRecentFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readFileChunk", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeRecentFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearRecentFiles", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = CapacitorMediastore()
    private let filePicker = FilePicker.shared

    // Debounce state для mediaLibraryChanged.
    private let observerQueue = DispatchQueue(label: "com.sangulov.plugins.mediastore.observer")
    private var pendingChangeTypes = Set<String>()
    private var pendingEmitWorkItem: DispatchWorkItem?

    // MARK: - Lifecycle

    override public func load() {
        super.load()
        PHPhotoLibrary.shared().register(self)
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioLibraryDidChange(_:)),
            name: .MPMediaLibraryDidChange,
            object: nil
        )
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        NotificationCenter.default.removeObserver(self, name: .MPMediaLibraryDidChange, object: nil)
        MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
    }

    // MARK: - PHPhotoLibraryChangeObserver

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Изменения PhotoKit могут касаться и фото, и видео в одном change-instance.
        // Лучше всего отдать оба типа — UI сам решит, что обновлять.
        scheduleEmit(types: ["photo", "video"])
    }

    @objc private func audioLibraryDidChange(_ notification: Notification) {
        scheduleEmit(types: ["audio"])
    }

    private func scheduleEmit(types: [String]) {
        observerQueue.async {
            self.pendingChangeTypes.formUnion(types)
            self.pendingEmitWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.observerQueue.async {
                    guard !self.pendingChangeTypes.isEmpty else { return }
                    let typesArr = Array(self.pendingChangeTypes)
                    self.pendingChangeTypes.removeAll()
                    DispatchQueue.main.async {
                        self.notifyListeners("mediaLibraryChanged", data: ["types": typesArr])
                    }
                }
            }
            self.pendingEmitWorkItem = work
            self.observerQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    // MARK: - Permissions

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        let result = implementation.checkPermissions()
        call.resolve(result)
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        implementation.requestPermissions { result in
            call.resolve(result)
        }
    }

    // MARK: - Albums

    @objc func getAlbums(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getAlbums { albums in
                call.resolve(["albums": albums])
            }
        }
    }

    // MARK: - Media

    @objc func getMedia(_ call: CAPPluginCall) {
        let albumId = call.getString("albumId")
        let limit = call.getInt("limit") ?? 20
        let offset = call.getInt("offset") ?? 0
        let type = call.getString("type") ?? "all"
        let cursor = call.getString("cursor")

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getMedia(
                albumId: albumId, limit: limit, offset: offset, type: type, cursor: cursor
            ) { result in
                call.resolve(result)
            }
        }
    }

    @objc func hasMedia(_ call: CAPPluginCall) {
        let type = call.getString("type") ?? "all"
        implementation.hasMedia(type: type) { available in
            call.resolve(["available": available])
        }
    }

    @objc func resolveMediaPath(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Must provide id"); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.resolveMediaPath(id: id) { result in
                call.resolve(result)
            }
        }
    }

    @objc func getThumbnail(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Must provide id"); return
        }
        let returnBase64 = call.getBool("returnBase64") ?? false
        let size = call.getInt("size") ?? 256
        let density = call.getDouble("density") ?? 1.0

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getThumbnail(
                id: id, returnBase64: returnBase64, size: size, density: density
            ) { result in
                call.resolve(result)
            }
        }
    }

    @objc func getThumbnails(_ call: CAPPluginCall) {
        guard let ids = call.getArray("ids", String.self) else {
            call.reject("Must provide ids array"); return
        }
        let size = call.getInt("size") ?? 256
        let density = call.getDouble("density") ?? 1.0

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getThumbnails(
                ids: ids, size: size, density: density
            ) { result in
                call.resolve(result)
            }
        }
    }

    @objc func prefetchThumbnails(_ call: CAPPluginCall) {
        guard let ids = call.getArray("ids", String.self) else {
            call.reject("Must provide ids array"); return
        }
        let size = call.getInt("size") ?? 256
        let density = call.getDouble("density") ?? 1.0

        // Fire-and-forget.
        DispatchQueue.global(qos: .utility).async {
            self.implementation.prefetchThumbnails(ids: ids, size: size, density: density)
        }
        call.resolve()
    }

    @objc func cancelPendingThumbnails(_ call: CAPPluginCall) {
        implementation.cancelPendingThumbnails()
        call.resolve()
    }

    // MARK: - File picker / Recent files

    @objc func pickFiles(_ call: CAPPluginCall) {
        let mimeTypes = call.getArray("mimeTypes", String.self) ?? []
        let multiple = call.getBool("multiple") ?? false

        DispatchQueue.main.async {
            guard let viewController = self.bridge?.viewController else {
                call.reject("No view controller available")
                return
            }
            self.filePicker.present(
                from: viewController,
                mimeTypes: mimeTypes,
                multiple: multiple
            ) { urls in
                guard let urls = urls else { call.resolve(["files": []]); return }
                if urls.isEmpty { call.resolve(["files": []]); return }
                self.filePicker.persist(urls: urls) { persisted in
                    call.resolve(["files": persisted])
                }
            }
        }
    }

    @objc func getRecentFiles(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 50
        let offset = call.getInt("offset") ?? 0
        let mimeFilters = call.getArray("mimeTypes", String.self) ?? []

        filePicker.list(limit: limit, offset: offset, mimeFilters: mimeFilters) { result in
            call.resolve(result)
        }
    }

    @objc func resolveRecentFile(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Must provide id"); return
        }
        filePicker.resolve(id: id) { dict in
            var result: [String: Any] = [:]
            result["file"] = dict ?? NSNull()
            call.resolve(result)
        }
    }

    @objc func readFileChunk(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Must provide id"); return
        }
        let offset = Int64(call.getInt("offset") ?? 0)
        let length = call.getInt("length") ?? 0

        filePicker.readFileChunk(id: id, offset: offset, length: length) { result in
            guard let r = result else {
                call.reject("Failed to read file chunk")
                return
            }
            call.resolve(r)
        }
    }

    @objc func removeRecentFile(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Must provide id"); return
        }
        filePicker.remove(id: id) { call.resolve() }
    }

    @objc func clearRecentFiles(_ call: CAPPluginCall) {
        filePicker.clear { call.resolve() }
    }
}
