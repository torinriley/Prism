// main.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Foundation
import Prism

// prism-bench — reproducible benchmarks for Prism. Run in release:
//   swift run -c release prism-bench [--suite ops,pipelines,cold,resources,instrumentation,optimizer,fusion,alu,texture,blur,precision|all]
//       [--resolutions 1080p,4k,large] [--iterations N] [--warmup N] [--image PATH] [--json PATH] [--quick]

#if DEBUG
FileHandle.standardError.write(Data("warning: DEBUG build — numbers are not meaningful. Use `swift run -c release prism-bench`.\n".utf8))
#endif

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

var settings = Settings()
if arguments.contains("--quick") { settings = Settings(iterations: 8, warmup: 2) }
if let n = option("--iterations").flatMap(Int.init) { settings.iterations = n }
if let n = option("--warmup").flatMap(Int.init) { settings.warmup = n }

let allSuites: Set<String> = ["ops", "pipelines", "cold", "resources", "instrumentation", "optimizer", "fusion", "alu", "texture", "blur", "precision"]
let requested = option("--suite") ?? "all"
let suites = requested == "all" ? allSuites : Set(requested.split(separator: ",").map(String.init))
guard suites.isSubset(of: allSuites) else {
    print("unknown suite in '\(requested)'. Available: \(allSuites.sorted().joined(separator: ", ")), all")
    exit(2)
}

let names = (option("--resolutions") ?? "1080p,4k,large").split(separator: ",").map(String.init)
let environment = Environment.capture(arguments: arguments)

print("# Prism benchmark")
print("""

- date: \(environment.date)
- machine: \(environment.hardwareModel), \(environment.cpu), \(String(format: "%.0f", environment.physicalMemoryGiB)) GiB, GPU \(environment.gpu) (unified memory: \(environment.unifiedMemory))
- OS: \(environment.os)
- build: \(environment.swiftBuild); thermal state: \(environment.thermalState); low power mode: \(environment.lowPowerMode)
- arguments: \(arguments.joined(separator: " "))
- method: median of \(settings.iterations) renders after \(settings.warmup) warm-up renders on one warmed `Renderer`; columns are medians. \
`total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; \
`gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
""")

var inputs: [(Resolution, CGImage)] = []
if let path = option("--image") {
    guard let image = loadImage(at: path) else { print("could not load image at \(path)"); exit(2) }
    inputs.append((Resolution(name: "file \(image.width)×\(image.height)", width: image.width, height: image.height), image))
    print("- input: \(path)")
} else {
    for name in names {
        guard let res = standardResolutions.first(where: { $0.name == name }) else { print("unknown resolution '\(name)'"); exit(2) }
        inputs.append((res, makeSyntheticImage(width: res.width, height: res.height)))
    }
    print("- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph")
}

let results: [CaseResult]
do {
    results = try await runSuites(suites, resolutions: inputs, settings: settings)
} catch {
    print("benchmark failed: \(error)")
    exit(1)
}

if let path = option("--json") {
    struct Report: Codable { var environment: Environment; var settings: [String: Int]; var results: [CaseResult] }
    let report = Report(environment: environment, settings: ["iterations": settings.iterations, "warmup": settings.warmup], results: results)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: path))
    print("\nwrote \(path)")
}
