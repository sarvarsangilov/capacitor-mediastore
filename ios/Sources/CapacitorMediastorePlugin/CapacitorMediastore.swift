import Foundation

@objc public class CapacitorMediastore: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}
