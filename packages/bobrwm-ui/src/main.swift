// Swift owns the process entry point and the AppKit lifecycle.
import AppKit
import BobrwmUIABI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coreStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let result: Int32
        if let path = Self.configPath() {
            result = path.withCString { bw_core_start($0) }
        } else {
            result = bw_core_start(nil)
        }

        guard result == 0 else {
            fputs("bobrwm: core initialization failed\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        coreStarted = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if coreStarted {
            bw_core_stop()
            coreStarted = false
        }
    }

    private static func configPath() -> String? {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return nil }

        for index in 1..<arguments.count where
            arguments[index] == "-c" || arguments[index] == "--config"
        {
            let valueIndex = arguments.index(after: index)
            return valueIndex < arguments.endIndex ? arguments[valueIndex] : nil
        }
        return nil
    }
}

@_cdecl("bw_app_terminate")
public func terminateApplication() {
    precondition(Thread.isMainThread)
    NSApplication.shared.terminate(nil)
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
