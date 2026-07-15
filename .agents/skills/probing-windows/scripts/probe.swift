import Foundation
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<UInt32>) -> AXError

enum ManageState: String, Codable {
    case reject, ready, pending
}

struct Bounds: Codable, Equatable {
    let x: Double, y: Double, w: Double, h: Double
}

struct WindowSample: Codable {
    let wid: UInt32
    let pid: Int
    let ownerName: String?
    let windowName: String?
    let windowKind: String
    let cgOrder: Int
    let cgLayer: Int
    let cgAlpha: Double
    let cgOnscreen: Bool
    let cgBounds: Bounds
    let role: String?
    let subrole: String?
    let title: String?
    let axFrame: Bounds?
    let minimized: Bool?
    let fullscreen: Bool?
    let focused: Bool
    let manageState: ManageState

    enum CodingKeys: String, CodingKey {
        case wid, pid
        case ownerName = "owner_name"
        case windowName = "window_name"
        case windowKind = "window_kind"
        case cgOrder = "cg_order"
        case cgLayer = "cg_layer"
        case cgAlpha = "cg_alpha"
        case cgOnscreen = "cg_onscreen"
        case cgBounds = "cg_bounds"
        case role, subrole, title
        case axFrame = "ax_frame"
        case minimized, fullscreen, focused
        case manageState = "manage_state"
    }
}

func manageStateFor(role: String?, subrole: String?) -> ManageState {
    guard let role = role else { return .pending }
    guard let subrole = subrole else { return .pending }
    if role == "AXWindow" && subrole == "AXStandardWindow" { return .ready }
    if role == "AXUnknown" || subrole == "AXUnknown" { return .pending }
    return .reject
}

struct AXWindowMeta {
    let role: String?
    let subrole: String?
    let title: String?
    let frame: Bounds?
    let minimized: Bool?
    let fullscreen: Bool?
}

struct AXAppMeta {
    let windows: [UInt32: AXWindowMeta]
    let focusedWid: UInt32
}

func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    return ref as? String
}

func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    return ref as? Bool
}

func copyFrame(_ element: AXUIElement) -> Bounds? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef, let sizeVal = sizeRef,
          CFGetTypeID(posVal) == AXValueGetTypeID(),
          CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
    return Bounds(x: point.x, y: point.y, w: size.width, h: size.height)
}

func collectAXMetadata(pid: pid_t) -> AXAppMeta {
    var windows: [UInt32: AXWindowMeta] = [:]
    let app = AXUIElementCreateApplication(pid)
    // Bound each AX message so a hung app AX server cannot stall the sampler.
    AXUIElementSetMessagingTimeout(app, 0.25)

    var focusedWid: UInt32 = 0
    var focusedRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
       let focusedVal = focusedRef, CFGetTypeID(focusedVal) == AXUIElementGetTypeID() {
        _ = _AXUIElementGetWindow(focusedVal as! AXUIElement, &focusedWid)
    }

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else {
        return AXAppMeta(windows: windows, focusedWid: focusedWid)
    }

    for win in axWindows {
        var wid: UInt32 = 0
        _ = _AXUIElementGetWindow(win, &wid)
        guard wid != 0 else { continue }

        windows[wid] = AXWindowMeta(
            role: copyString(win, kAXRoleAttribute),
            subrole: copyString(win, kAXSubroleAttribute),
            title: copyString(win, kAXTitleAttribute),
            frame: copyFrame(win),
            minimized: copyBool(win, kAXMinimizedAttribute),
            fullscreen: copyBool(win, "AXFullScreen"))
    }
    return AXAppMeta(windows: windows, focusedWid: focusedWid)
}

func collectSamples(pidFilter: pid_t?, widFilter: UInt32?, axPids: Set<pid_t>?,
                    includeDimmingOverlays: Bool) -> [WindowSample] {
    var axMetadataByPid: [pid_t: AXAppMeta] = [:]
    var samples: [WindowSample] = []

    guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return samples
    }

    for (cgOrder, info) in windowList.enumerated() {
        guard let infoPid = info[kCGWindowOwnerPID as String] as? Int,
              let wid = info[kCGWindowNumber as String] as? UInt32 else { continue }
        let ownerPid = pid_t(infoPid)
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 0
        let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
        let ownerName = info[kCGWindowOwnerName as String] as? String
        let windowName = info[kCGWindowName as String] as? String

        // Dimming is implemented with bobrwm-owned, normal-level NSPanels.
        // Other bobrwm UI (status item and tile preview) uses elevated levels,
        // so owner + layer identifies the dim panels without AX access.
        let isDimmingOverlay = ownerName?.lowercased() == "bobrwm" && layer == 0
        let matchesPid = pidFilter.map { ownerPid == $0 } ?? true
        let matchesWid = widFilter.map { wid == $0 } ?? true
        if !(matchesPid && matchesWid) && !(includeDimmingOverlays && isDimmingOverlay) { continue }

        var bounds = Bounds(x: 0, y: 0, w: 0, h: 0)
        if let boundsDict = info[kCGWindowBounds as String] as? [String: Double] {
            bounds = Bounds(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                w: boundsDict["Width"] ?? 0, h: boundsDict["Height"] ?? 0)
        }

        // Only pay the AX cost for pids the caller cares about; in snapshot
        // mode that avoids querying every process on the system.
        let wantAX = !isDimmingOverlay && (axPids == nil || axPids!.contains(ownerPid))
        if wantAX && axMetadataByPid[ownerPid] == nil {
            axMetadataByPid[ownerPid] = collectAXMetadata(pid: ownerPid)
        }
        let appMeta = axMetadataByPid[ownerPid]
        let ax = appMeta?.windows[wid]
        let state = manageStateFor(role: ax?.role, subrole: ax?.subrole)

        samples.append(WindowSample(
            wid: wid, pid: infoPid, ownerName: ownerName, windowName: windowName,
            windowKind: isDimmingOverlay ? "dimming_overlay" : "window", cgOrder: cgOrder,
            cgLayer: layer, cgAlpha: alpha, cgOnscreen: onScreen,
            cgBounds: bounds, role: ax?.role, subrole: ax?.subrole,
            title: ax?.title, axFrame: ax?.frame,
            minimized: ax?.minimized, fullscreen: ax?.fullscreen,
            focused: appMeta.map { $0.focusedWid == wid } ?? false,
            manageState: state))
    }

    return samples.sorted { $0.cgOrder < $1.cgOrder }
}

/// Fields whose transitions are worth a `change` event. Frame moves use a 1px
/// epsilon and alpha a 0.01 epsilon so animation jitter does not flood output.
func changedFields(_ prev: WindowSample, _ cur: WindowSample) -> [String] {
    var fields: [String] = []
    if prev.manageState != cur.manageState { fields.append("manage_state") }
    if prev.role != cur.role { fields.append("role") }
    if prev.subrole != cur.subrole { fields.append("subrole") }
    if prev.cgOnscreen != cur.cgOnscreen { fields.append("cg_onscreen") }
    if prev.cgOrder != cur.cgOrder { fields.append("cg_order") }
    if abs(prev.cgAlpha - cur.cgAlpha) > 0.01 { fields.append("cg_alpha") }
    if abs(prev.cgBounds.x - cur.cgBounds.x) > 1 || abs(prev.cgBounds.y - cur.cgBounds.y) > 1
        || abs(prev.cgBounds.w - cur.cgBounds.w) > 1 || abs(prev.cgBounds.h - cur.cgBounds.h) > 1 {
        fields.append("cg_bounds")
    }
    if prev.minimized != cur.minimized { fields.append("minimized") }
    if prev.fullscreen != cur.fullscreen { fields.append("fullscreen") }
    if prev.focused != cur.focused { fields.append("focused") }
    return fields
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
    let fieldsChanged: [String]?
    let wid: UInt32?
    let previous: WindowSample?
    let current: WindowSample?
    let samples: UInt64?

    enum CodingKeys: String, CodingKey {
        case type, pid, wallTime = "wall_time", sampleIndex = "sample_index"
        case durationMs = "duration_ms", intervalMs = "interval_ms"
        case elapsedMs = "elapsed_ms", windowCount = "window_count"
        case windows, change, fieldsChanged = "fields_changed"
        case wid, previous, current, samples
    }

    static func sample(pid: pid_t?, index: UInt64, elapsed: UInt64, windows: [WindowSample]) -> Event {
        Event(type: "sample", pid: pid.map { Int($0) }, durationMs: nil,
            intervalMs: nil, wallTime: isoNow(), sampleIndex: index,
            elapsedMs: elapsed, windowCount: windows.count, windows: windows,
            change: nil, fieldsChanged: nil, wid: nil, previous: nil, current: nil, samples: nil)
    }

    static func change(pid: pid_t?, index: UInt64, elapsed: UInt64, change: String,
                       fields: [String]?, wid: UInt32, previous: WindowSample?, current: WindowSample?) -> Event {
        Event(type: "change", pid: pid.map { Int($0) }, durationMs: nil,
            intervalMs: nil, wallTime: isoNow(), sampleIndex: index,
            elapsedMs: elapsed, windowCount: nil, windows: nil,
            change: change, fieldsChanged: fields, wid: wid,
            previous: previous, current: current, samples: nil)
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

func usage(_ message: String? = nil) -> Never {
    if let message = message {
        fputs("error: \(message)\n", stderr)
    }
    fputs("""
    usage: probe [--pid <pid>] [--wid <cg-window-id>] [--include-dimming-overlays]
                 [--duration-ms N] [--interval-ms N]
           probe --snapshot [--ax-pids <pid,pid,...>]

    Sampling mode emits session_start/sample/change/session_end JSONL events.
    Snapshot mode emits a single sample event covering every CG window on the
    system; AX attributes are collected only for --ax-pids to stay fast.

    """, stderr)
    exit(2)
}

// --- main ---

let args = CommandLine.arguments
var pidArg: pid_t?
var widArg: UInt32?
var durationMs: UInt64 = 10000
var intervalMs: UInt64 = 100
var snapshotMode = false
var axPidsArg: Set<pid_t>?
var includeDimmingOverlays = false
var i = 1
while i < args.count {
    switch args[i] {
    case "--pid":
        guard i + 1 < args.count, let value = Int32(args[i + 1]), value > 0 else {
            usage("invalid --pid value")
        }
        pidArg = pid_t(value)
        i += 2
    case "--duration-ms":
        guard i + 1 < args.count, let value = UInt64(args[i + 1]), value > 0 else {
            usage("invalid --duration-ms value")
        }
        durationMs = value
        i += 2
    case "--interval-ms":
        guard i + 1 < args.count, let value = UInt64(args[i + 1]), value > 0 else {
            usage("invalid --interval-ms value")
        }
        intervalMs = value
        i += 2
    case "--wid":
        guard i + 1 < args.count, let value = UInt32(args[i + 1]), value > 0 else {
            usage("invalid --wid value")
        }
        widArg = value
        i += 2
    case "--snapshot":
        snapshotMode = true
        i += 1
    case "--include-dimming-overlays":
        includeDimmingOverlays = true
        i += 1
    case "--ax-pids":
        guard i + 1 < args.count else { usage("missing --ax-pids value") }
        var pids: Set<pid_t> = []
        for part in args[i + 1].split(separator: ",") {
            guard let value = Int32(part.trimmingCharacters(in: .whitespaces)), value > 0 else {
                usage("invalid --ax-pids entry '\(part)'")
            }
            pids.insert(pid_t(value))
        }
        axPidsArg = pids
        i += 2
    default:
        usage("unknown argument \(args[i])")
    }
}

if snapshotMode {
    // One CG pass over every window; AX only for the requested pids.
    let windows = collectSamples(pidFilter: pidArg, widFilter: widArg, axPids: axPidsArg ?? [],
        includeDimmingOverlays: includeDimmingOverlays)
    emitCodable(Event.sample(pid: pidArg, index: 0, elapsed: 0, windows: windows))
    exit(0)
}

if pidArg == nil && widArg == nil {
    usage("either --pid or --wid is required (or use --snapshot)")
}

emitCodable(Event(type: "session_start", pid: pidArg.map { Int($0) }, durationMs: durationMs,
    intervalMs: intervalMs, wallTime: isoNow(), sampleIndex: nil, elapsedMs: nil,
    windowCount: nil, windows: nil, change: nil, fieldsChanged: nil, wid: widArg,
    previous: nil, current: nil, samples: nil))

var previousByWid: [UInt32: WindowSample] = [:]
let startTime = CFAbsoluteTimeGetCurrent()
var sampleIndex: UInt64 = 0

while true {
    let elapsed = UInt64((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
    if elapsed > durationMs { break }

    let current = collectSamples(pidFilter: pidArg, widFilter: widArg, axPids: nil,
        includeDimmingOverlays: includeDimmingOverlays)
    let currentByWid = Dictionary(uniqueKeysWithValues: current.map { ($0.wid, $0) })

    emitCodable(Event.sample(pid: pidArg, index: sampleIndex, elapsed: elapsed, windows: current))

    for s in current {
        if let prev = previousByWid[s.wid] {
            let fields = changedFields(prev, s)
            if !fields.isEmpty {
                emitCodable(Event.change(pid: pidArg, index: sampleIndex, elapsed: elapsed,
                    change: "changed", fields: fields, wid: s.wid, previous: prev, current: s))
            }
        } else {
            emitCodable(Event.change(pid: pidArg, index: sampleIndex, elapsed: elapsed,
                change: "added", fields: nil, wid: s.wid, previous: nil, current: s))
        }
    }

    for (wid, prev) in previousByWid {
        if currentByWid[wid] == nil {
            emitCodable(Event.change(pid: pidArg, index: sampleIndex, elapsed: elapsed,
                change: "removed", fields: nil, wid: wid, previous: prev, current: nil))
        }
    }

    previousByWid = currentByWid
    sampleIndex += 1
    if elapsed >= durationMs { break }
    usleep(UInt32(intervalMs * 1000))
}

emitCodable(Event(type: "session_end", pid: pidArg.map { Int($0) }, durationMs: nil,
    intervalMs: nil, wallTime: isoNow(), sampleIndex: nil, elapsedMs: nil,
    windowCount: nil, windows: nil, change: nil, fieldsChanged: nil, wid: nil,
    previous: nil, current: nil, samples: sampleIndex))
