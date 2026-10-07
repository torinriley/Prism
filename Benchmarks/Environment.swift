// Environment.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation
import Metal

/// Everything needed to interpret (and reproduce) a result.
struct Environment: Codable {
    var date: String
    var hardwareModel: String
    var cpu: String
    var physicalMemoryGiB: Double
    var gpu: String
    var unifiedMemory: Bool
    var os: String
    var swiftBuild: String
    var thermalState: String
    var lowPowerMode: Bool
    var arguments: [String]

    static func capture(arguments: [String]) -> Environment {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buffer, &size, nil, 0)
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let info = ProcessInfo.processInfo
        let thermal = ["nominal", "fair", "serious", "critical"][min(info.thermalState.rawValue, 3)]
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let device = MTLCreateSystemDefaultDevice()
        return Environment(
            date: ISO8601DateFormatter().string(from: Date()),
            hardwareModel: sysctl("hw.model"),
            cpu: sysctl("machdep.cpu.brand_string"),
            physicalMemoryGiB: Double(info.physicalMemory) / 1_073_741_824,
            gpu: device?.name ?? "none",
            unifiedMemory: device?.hasUnifiedMemory ?? false,
            os: info.operatingSystemVersionString,
            swiftBuild: build,
            thermalState: thermal,
            lowPowerMode: info.isLowPowerModeEnabled,
            arguments: arguments)
    }
}
