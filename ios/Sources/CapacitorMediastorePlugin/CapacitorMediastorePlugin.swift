import Foundation
import Capacitor

/**
 * CapacitorMediastorePlugin — Capacitor 8.x plugin для iOS.
 *
 * Предоставляет доступ к фото/видео галерее через Photos framework.
 * Методы: checkPermissions, requestPermissions, getAlbums, getMedia,
 *         getThumbnail (lazy, file URL), getThumbnails (batch, file URLs).
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
        CAPPluginMethod(name: "getThumbnails", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = CapacitorMediastore()

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
                albumId: albumId,
                limit: limit,
                offset: offset,
                type: type
            ) { result in
                call.resolve(result)
            }
        }
    }

    @objc func getThumbnail(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Must provide id")
            return
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
            call.reject("Must provide ids array")
            return
        }
        let size = call.getInt("size") ?? 256

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getThumbnails(ids: ids, size: size) { result in
                call.resolve(result)
            }
        }
    }
}
