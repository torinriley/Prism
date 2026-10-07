// Signposts.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import os

enum Signposts {
    private static let enabled = OSSignposter(subsystem: "dev.prism", category: "Render")

    /// A no-op signposter when instrumentation is off, so call sites need no branching.
    static func signposter(for level: InstrumentationLevel) -> OSSignposter {
        level == .off ? .disabled : enabled
    }
}
