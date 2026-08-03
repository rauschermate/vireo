import os

/// Points-of-interest signposts for the complete source-to-pixel pipeline.
/// They are effectively free when no Instruments trace is collecting them and
/// give performance work stable phase names across the app and benchmark.
public enum VireoPerformanceTrace {
    public static let log = OSLog(subsystem: "com.materauscher.vireo",
                                  category: .pointsOfInterest)

    @discardableResult
    public static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    public static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    public static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
