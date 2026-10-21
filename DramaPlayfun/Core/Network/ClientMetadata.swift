import Darwin
import Foundation
import UIKit

nonisolated struct ClientMetadata: Sendable {
    let appVersion: String
    let modelName: String
    let platform: String
    let systemVersion: String

    var headers: [String: String] {
        ["appVersion": appVersion, "modelName": modelName,
         "platform": platform, "systemVersion": systemVersion]
    }

    @MainActor
    static var current: Self {
        let device = UIDevice.current
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName: String
        #if targetEnvironment(simulator)
        modelName = "Simulator"
        #else
        var systemInfo = utsname()
        if uname(&systemInfo) == 0 {
            let identifier = withUnsafeBytes(of: systemInfo.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            modelName = DeviceModelName.resolve(identifier)
        } else {
            modelName = device.model
        }
        #endif
        return Self(appVersion: version.flatMap { $0.isEmpty ? nil : $0 } ?? "1.0",
                    modelName: modelName, platform: "iOS",
                    systemVersion: "\(device.systemName) \(device.systemVersion)")
    }
}
