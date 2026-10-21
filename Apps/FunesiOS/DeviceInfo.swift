import UIKit

enum DeviceInfo {
    /// The hardware model, such as "iPhone14,4", which the Mac shows in its Allow prompt.
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The name to pair under. iOS reports just "iPhone" without a special entitlement, so the
    /// pairing sheet lets the user change it.
    @MainActor static var name: String { UIDevice.current.name }
}
