import Foundation
import Capacitor
import UIKit

/**
 * CapacitorMediastorePlugin — Capacitor 8.x plugin для iOS.
 *
 * Подключает две области:
 *  1) Медиагалерея — фото/видео (Photos framework) и аудио (MPMediaLibrary).
 *  2) Файлпикер с «недавними файлами» — UIDocumentPickerViewController +
 *     security-scoped bookmarks (см. FilePicker.swift).
 */
@objc(CapacitorMediastorePlugin)
public class CapacitorMediastorePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "CapacitorMediastorePlugin"
    public let jsName = "CapacitorMediastore"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAlbums", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getMedia", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getThumbnail", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getThumbnails", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getRecentFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveRecentFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeRecentFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearRecentFiles", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = CapacitorMediastore()
    private let filePicker = FilePicker.shared

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

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getMedia(
                albumId: albumId, limit: limit, offset: offset, type: type
            ) { result in
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

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getThumbnail(id: id, returnBase64: returnBase64, size: size) { result in
                call.resolve(result)
            }
        }
    }

    @objc func getThumbnails(_ call: CAPPluginCall) {
        guard let ids = call.getArray("ids", String.self) else {
            call.reject("Must provide ids array"); return
        }
        let size = call.getInt("size") ?? 256

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getThumbnails(ids: ids, size: size) { result in
                call.resolve(result)
            }
        }
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
                guard let urls = urls else {
                    // отмена пользователем
                    call.resolve(["files": []])
                    return
                }
                if urls.isEmpty {
                    call.resolve(["files": []])
                    return
                }
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

    @objc func removeRecentFile(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Must provide id"); return
        }
        filePicker.remove(id: id) {
            call.resolve()
        }
    }

    @objc func clearRecentFiles(_ call: CAPPluginCall) {
        filePicker.clear {
            call.resolve()
        }
    }
}
