import Foundation
import Capacitor

/**
 * CapacitorMediastorePlugin — Capacitor 8.x plugin для iOS.
 *
 * Предоставляет доступ к фото/видео галерее через Photos framework.
 * Методы: checkPermissions, requestPermissions, getAlbums, getMedia.
 */
@objc(CapacitorMediastorePlugin)
public class CapacitorMediastorePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "CapacitorMediastorePlugin"
    public let jsName = "CapacitorMediastore"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAlbums", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getMedia", returnType: CAPPluginReturnPromise)
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

        DispatchQueue.global(qos: .userInitiated).async {
            self.implementation.getThumbnail(id: id) { result in
                call.resolve(result)
            }
        }
    }
}
