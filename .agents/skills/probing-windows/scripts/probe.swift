import Foundation
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<UInt32>) -> AXError

enum ManageState: String, Codable {
    case reject, ready, pending
}

struct WindowSample: Codable {
    let wid: UInt32
    let cgLayer: Int
    let cgAlpha: Double
    let cgOnscreen: Bool
    let cgBounds: Bounds
    let role: String?
    let subrole: String?
    let title: String?
    let manageState: ManageState

    enum CodingKeys: String, CodingKey {
        case wid
        case cgLayer = "cg_layer"
        case cgAlpha = "cg_alpha"
        case cgOnscreen = "cg_onscreen"
        case cgBounds = "cg_bounds"
        case role, subrole, title
        case manageState = "manage_state"
    }
}

struct Bounds: Codable {
    let x: Double, y: Double, w: Double, h: Double
}

func manageStateFor(role: String?, subrole: String?) -> ManageState {
    guard let role = role else { return .pending }
    guard let subrole = subrole else { return .pending }
    if role == "AXWindow" && subrole == "AXStandardWindow" { return .ready }
    if role == "AXUnknown" || subrole == "AXUnknown" { return .pending }
    return .reject
}

func collectAXMetadata(pid: pid_t) -> [UInt32: (role: String?, subrole: String?, title: String?)] {
    var result: [UInt32: (role: String?, subrole: String?, title: String?)] = [:]
    let app = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return result }

    for win in windows {
        var wid: UInt32 = 0
        _ = _AXUIElementGetWindow(win, &wid)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        if wid != 0 {
            result[wid] = (role, subrole, title)
        }
    }
    return result
}

func collectSamples(pid: pid_t) -> [WindowSample] {
    let axMeta = collectAXMetadata(pid: pid)
    var samples: [WindowSample] = []

    guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return samples
    }

    for info in windowList {
        guard let infoPid = info[kCGWindowOwnerPID as String] as? Int,
              pid_t(infoPid) == pid,
              let wid = info[kCGWindowNumber as String] as? UInt32 else { continue }

        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 0
        let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false

        var bounds = Bounds(x: 0, y: 0, w: 0, h: 0)
        if let boundsDict = info[kCGWindowBounds as String] as? [String: Double] {
            bounds = Bounds(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                w: boundsDict["Width"] ?? 0, h: boundsDict["Height"] ?? 0)
        }

        let ax = axMeta[wid]
        let state = manageStateFor(role: ax?.role, subrole: ax?.subrole)

        samples.append(WindowSample(
            wid: wid, cgLayer: layer, cgAlpha: alpha, cgOnscreen: onScreen,
            cgBounds: bounds, role: ax?.role, subrole: ax?.subrole,
            title: ax?.title, manageState: state))
    }

    return samples.sorted { $0.wid < $1.wid }
}

struct Event: Codable {
    let type: String
    let pid: Int?
    let durationMs: UInt64?
    let intervalMs: UInt64?
    let wallTime: String?
    let sampleIndex: UInt64?
    let elapsedMs: UInt64?
    let windowCount: Int?
    let windows: [WindowSample]?
    let change: String?
    let wid: UInt32?
    let previous: WindowSample?
    let current: WindowSample?
    let samples: UInt64?

    enum CodingKeys: String, CodingKey {
        case type, pid, wallTime = "wall_time", sampleIndex = "sample_index"
        case durationMs = "duration_ms", intervalMs = "interval_ms"
        case elapsedMs = "elapsed_ms", windowCount = "window_count"
        case windows, change, wid, previous, current, samples
    }
}

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

func emitCodable<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

// --- main ---

let args = CommandLine.arguments
var pidArg: pid_t = 0
var durationMs: UInt64 = 10000
var intervalMs: UInt64 = 100
var i = 1
while i < args.count {
    switch args[i] {
    case "--pid":
        i += 1; pidArg = pid_t(args[i])!
    case "--duration-ms":
        i += 1; durationMs = UInt64(args[i])!
    case "--interval-ms":
        i += 1; intervalMs = UInt64(args[i])!
    default: break
    }
    i += 1
}

guard pidArg > 0 else {
    fputs("usage: probe --pid <pid> [--duration-ms N] [--interval-ms N]\n", stderr)
    exit(2)
}

emitCodable(Event(type: "session_start", pid: Int(pidArg), durationMs: durationMs,
    intervalMs: intervalMs, wallTime: isoNow(), sampleIndex: nil, elapsedMs: nil,
    windowCount: nil, windows: nil, change: nil, wid: nil, previous: nil, current: nil, samples: nil))

var previousByWid: [UInt32: WindowSample] = [:]
let startTime = CFAbsoluteTimeGetCurrent()
var sampleIndex: UInt64 = 0

while true {
    let elapsed = UInt64((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
    if elapsed > durationMs { break }

    let current = collectSamples(pid: pidArg)
    let currentByWid = Dictionary(uniqueKeysWithValues: current.map { ($0.wid, $0) })

    emitCodable(Event(type: "sample", pid: Int(pidArg), durationMs: nil,
        intervalMs: nil, wallTime: isoNow(), sampleIndex: sampleIndex,
        elapsedMs: elapsed, windowCount: current.count, windows: current,
        change: nil, wid: nil, previous: nil, current: nil, samples: nil))

    for s in current {
        if let prev = previousByWid[s.wid] {
            if prev.manageState != s.manageState || prev.role != s.role || prev.subrole != s.subrole || prev.cgOnscreen != s.cgOnscreen {
                emitCodable(Event(type: "change", pid: Int(pidArg), durationMs: nil,
                    intervalMs: nil, wallTime: isoNow(), sampleIndex: sampleIndex,
                    elapsedMs: elapsed, windowCount: nil, windows: nil,
                    change: "changed", wid: s.wid, previous: prev, current: s, samples: nil))
            }
        } else {
            emitCodable(Event(type: "change", pid: Int(pidArg), durationMs: nil,
                intervalMs: nil, wallTime: isoNow(), sampleIndex: sampleIndex,
                elapsedMs: elapsed, windowCount: nil, windows: nil,
                change: "added", wid: nil, previous: nil, current: s, samples: nil))
        }
    }

    for (wid, prev) in previousByWid {
        if currentByWid[wid] == nil {
            emitCodable(Event(type: "change", pid: Int(pidArg), durationMs: nil,
                intervalMs: nil, wallTime: isoNow(), sampleIndex: sampleIndex,
                elapsedMs: elapsed, windowCount: nil, windows: nil,
                change: "removed", wid: wid, previous: prev, current: nil, samples: nil))
        }
    }

    previousByWid = currentByWid
    sampleIndex += 1
    if elapsed >= durationMs { break }
    usleep(UInt32(intervalMs * 1000))
}

emitCodable(Event(type: "session_end", pid: Int(pidArg), durationMs: nil,
    intervalMs: nil, wallTime: isoNow(), sampleIndex: nil, elapsedMs: nil,
    windowCount: nil, windows: nil, change: nil, wid: nil, previous: nil,
    current: nil, samples: sampleIndex))
