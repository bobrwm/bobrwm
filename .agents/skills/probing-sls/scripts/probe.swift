import Foundation
import ApplicationServices

enum ProbeError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

struct Libraries {
    let handles: [(String, UnsafeMutableRawPointer)]

    init() throws {
        var loaded: [(String, UnsafeMutableRawPointer)] = []
        for (name, path) in [
            ("SkyLight", "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"),
            ("CoreGraphics", "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"),
            ("CoreFoundation", "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        ] {
            guard let handle = dlopen(path, RTLD_LAZY) else {
                for (_, previous) in loaded { dlclose(previous) }
                throw ProbeError.message("cannot load \(name)")
            }
            loaded.append((name, handle))
        }
        handles = loaded
    }

    func close() {
        for (_, handle) in handles { dlclose(handle) }
    }

    func find(_ symbol: String) -> (String, UnsafeMutableRawPointer)? {
        for (library, handle) in handles {
            if let address = dlsym(handle, symbol) { return (library, address) }
        }
        return nil
    }

    func bind<T>(_ symbol: String, as type: T.Type) throws -> T {
        guard let (_, address) = find(symbol) else {
            throw ProbeError.message("required symbol unavailable: \(symbol)")
        }
        return unsafeBitCast(address, to: type)
    }
}

struct Options {
    var displays: [UInt32] = []
    var duration: Double = 0
    var intervalMs: Double = 100
    var allSamples = false
    var symbols: [String] = []

    init() throws {
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            if argument == "--all-samples" { allSamples = true; continue }
            if argument == "--help" {
                print("probe [--display ID] [--duration SEC] [--interval-ms MS] [--all-samples] [--symbol NAME]")
                exit(0)
            }
            guard let value = arguments.next() else { throw ProbeError.message("missing value for \(argument)") }
            switch argument {
            case "--display":
                guard let id = UInt32(value), id > 0 else { throw ProbeError.message("invalid display ID") }
                if !displays.contains(id) { displays.append(id) }
            case "--duration":
                guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
                    throw ProbeError.message("duration must be finite and nonnegative")
                }
                duration = seconds
            case "--interval-ms":
                guard let milliseconds = Double(value), milliseconds.isFinite, milliseconds > 0 else {
                    throw ProbeError.message("interval-ms must be finite and positive")
                }
                intervalMs = milliseconds
            case "--symbol": symbols.append(value)
            default: throw ProbeError.message("unknown argument: \(argument)")
            }
        }
    }
}

struct Observation: Equatable {
    let spaceId: UInt64?
    let isAnimating: Bool?
    let unavailable: [String: String]
}

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func sample(_ libraries: Libraries, _ options: Options) throws {
    typealias Connection = @convention(c) () -> Int32
    typealias CreateUUID = @convention(c) (UInt32) -> Unmanaged<CFUUID>?
    typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    typealias IsAnimating = @convention(c) (Int32, CFString) -> Bool
    let connection = try libraries.bind("SLSMainConnectionID", as: Connection.self)()
    let createUUID = try libraries.bind("CGDisplayCreateUUIDFromDisplayID", as: CreateUUID.self)
    let currentSpace = try? libraries.bind("SLSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)
    let isAnimating = try? libraries.bind("SLSManagedDisplayIsAnimating", as: IsAnimating.self)
    let displays = options.displays.isEmpty ? [CGMainDisplayID()] : options.displays
    var names: [(UInt32, CFString)] = []
    for display in displays {
        guard CGDisplayIsActive(display) != 0 else { throw ProbeError.message("display \(display) is not active") }
        guard let uuid = createUUID(display)?.takeRetainedValue(), let name = CFUUIDCreateString(nil, uuid) else {
            throw ProbeError.message("cannot resolve UUID for display \(display)")
        }
        names.append((display, name))
    }

    let start = ProcessInfo.processInfo.systemUptime
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var previous: [UInt32: Observation] = [:]
    var sampleCount = 0
    var emittedCount = 0
    while true {
        for (display, name) in names {
            guard CGDisplayIsActive(display) != 0 else { throw ProbeError.message("display \(display) disconnected") }
            let spaceId = currentSpace?(connection, name)
            let animation = isAnimating?(connection, name)
            var unavailable: [String: String] = [:]
            if currentSpace == nil { unavailable["space_id"] = "symbol unavailable: SLSManagedDisplayGetCurrentSpace" }
            if spaceId == 0 { unavailable["space_id"] = "WindowServer returned no current Space" }
            if isAnimating == nil { unavailable["is_animating"] = "symbol unavailable: SLSManagedDisplayIsAnimating" }
            let observation = Observation(spaceId: spaceId == 0 ? nil : spaceId, isAnimating: animation, unavailable: unavailable)
            sampleCount += 1
            guard options.allSamples || previous[display] != observation else { continue }
            try emit([
                "type": "sample", "display_id": display,
                "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                "wall_time": formatter.string(from: Date()),
                "space_id": observation.spaceId.map { $0 as Any } ?? NSNull(),
                "is_animating": animation.map { $0 as Any } ?? NSNull(),
                "unavailable": unavailable
            ])
            previous[display] = observation
            emittedCount += 1
        }
        let remaining = options.duration - (ProcessInfo.processInfo.systemUptime - start)
        if remaining <= 0 { break }
        Thread.sleep(forTimeInterval: min(options.intervalMs / 1000, remaining))
    }
    try emit(["type": "summary", "sample_count": sampleCount, "emitted_count": emittedCount])
}

do {
    let options = try Options()
    let libraries = try Libraries()
    defer { libraries.close() }
    if options.symbols.isEmpty {
        try sample(libraries, options)
    } else {
        for symbol in options.symbols {
            let resolved = libraries.find(symbol)
            try emit([
                "type": "symbol", "symbol": symbol, "available": resolved != nil,
                "library": resolved.map { $0.0 as Any } ?? NSNull()
            ])
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
