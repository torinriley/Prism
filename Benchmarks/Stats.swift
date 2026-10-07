// Stats.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation

/// Summary of repeated measurements of one quantity (seconds).
struct Summary: Codable {
    var median: Double
    var min: Double
    var p95: Double
    var mean: Double
    var stddev: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        precondition(!sorted.isEmpty)
        median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        min = sorted[0]
        p95 = sorted[Swift.min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let average = sorted.reduce(0, +) / Double(sorted.count)
        mean = average
        stddev = (sorted.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(sorted.count)).squareRoot()
    }
}

func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
