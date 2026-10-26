// Renders the real menu bar UI to light and dark PNGs for `zig build ui-preview`.
// The menu flashes on screen while it is captured.

import AppKit
import BobrwmUIABI
import SwiftUI

struct Sample {
    let id: UInt8
    let name: String
    let shortcut: Shortcut?
    let count: UInt32
    var isActive = false
    var isFocused = false
}

let sampleCounts: [UInt8: UInt32] = [1: 2, 2: 1, 3: 3]

let sampleApplications: [UInt8: [String]] = [
    1: ["Finder"],
    2: ["Safari"],
    3: ["Notes", "Preview"],
]

// The built-in defaults: ten unnamed workspaces, the first nine bound.
let samples: [Sample] = (1...10).map { id in
    Sample(
        id: id,
        name: "",
        shortcut: id < 10 ? .init(key: "\(id)", modifiers: .option) : nil,
        count: sampleCounts[id] ?? 0,
        isActive: id <= 2,
        isFocused: id == 1
    )
}

final class PreviewMenuActions: NSObject, StatusMenuActions {
    func switchToWorkspace(_ sender: NSMenuItem) {}
    func retile(_ sender: NSMenuItem) {}
    func reloadConfig(_ sender: NSMenuItem) {}
    func openConfig(_ sender: NSMenuItem) {}
    func showAbout(_ sender: NSMenuItem) {}
    func showSettings(_ sender: NSMenuItem) {}
    func quit(_ sender: NSMenuItem) {}
}

/// Display order can differ from numeric workspace order.
func makeStatusModel() -> StatusModel {
    let model = StatusModel()
    model.chips = makeSettingsModel(accessibilityGranted: true).workspaces
        .filter(\.isActive)
        .reversed()
        .map(StatusModel.Chip.init)
    return model
}

struct StatusPreview: View {
    let statusModel: StatusModel
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            StatusBarView(model: statusModel)
            Image(systemName: "magnifyingglass")
            Text("Wed 21 Oct  9:41")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 30)
        // Opaque, so the render reads like a real menu bar in any viewer.
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.92))
    }
}

// `popUp` blocks until `cancelTracking`, so the capture runs from a timer.
@MainActor
func renderMenu(path: String, appearance: NSAppearance.Name) -> Bool {
    let model = makeSettingsModel(accessibilityGranted: true)
    let actions = PreviewMenuActions()
    let statusMenu = StatusMenu()
    statusMenu.rebuild(
        workspaces: model.workspaces,
        target: actions
    )
    NSApplication.shared.appearance = NSAppearance(named: appearance)

    // The menu window can take a few ticks to appear.
    var png: Data?
    var attempts = 0
    let capture = Timer(timeInterval: 0.1, repeats: true) { timer in
        attempts += 1
        let menuWindow = NSApplication.shared.windows.first {
            $0.isVisible && String(describing: type(of: $0)).contains("Menu")
        }
        if attempts >= 3, let frameView = menuWindow?.contentView?.superview,
            let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            png = rep.representation(using: .png, properties: [:])
        }
        guard png != nil || attempts >= 20 else { return }
        timer.invalidate()
        statusMenu.menu.cancelTracking()
    }
    // Private API, but this harness never ships.
    let highlight = Timer(timeInterval: 0.15, repeats: false) { _ in
        let selector = Selector(("highlightItem:"))
        guard statusMenu.menu.responds(to: selector), statusMenu.menu.items.count > 3 else { return }
        statusMenu.menu.perform(selector, with: statusMenu.menu.items[3])
    }
    RunLoop.main.add(highlight, forMode: .common)
    RunLoop.main.add(capture, forMode: .common)

    // From the top of the screen so the menu does not scroll.
    let top = NSScreen.main?.visibleFrame.maxY ?? 800
    statusMenu.menu.popUp(positioning: nil, at: NSPoint(x: 40, y: top - 10), in: nil)
    NSApplication.shared.appearance = nil

    guard let png else {
        FileHandle.standardError.write(Data("menu capture failed: \(path)\n".utf8))
        return false
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print(path)
        return true
    } catch {
        FileHandle.standardError.write(Data("write failed: \(path): \(error)\n".utf8))
        return false
    }
}

func makeSettingsModel(accessibilityGranted: Bool) -> SettingsModel {
    let model = SettingsModel(
        configPath: "/Users/example/.config/bobrwm/config.zon",
        accessibilityGranted: accessibilityGranted
    )
    model.setWorkspaces(samples.map {
        WorkspaceInfo(id: $0.id, name: $0.name, shortcut: $0.shortcut)
    })
    model.setWorkspaceStates(Dictionary(uniqueKeysWithValues: samples.map {
        ($0.id, WorkspaceRuntimeState(
            applicationNames: sampleApplications[$0.id] ?? [],
            windowCount: $0.count,
            isActive: $0.isActive,
            isFocused: $0.isFocused,
            displayOrder: $0.isActive ? $0.id : UInt8.max
        ))
    }))
    model.setAppRules([
        AppRule(appID: "com.apple.Safari", workspace: 2),
        AppRule(appID: "com.apple.Notes", workspace: 3),
        AppRule(appID: "com.apple.mail", workspace: 4),
        AppRule(appID: "com.apple.iCal", workspace: 5),
        AppRule(appID: "com.apple.Music", workspace: 6),
        AppRule(appID: "com.apple.systempreferences", floats: true),
        AppRule(appID: "com.apple.calculator", floats: true),
        AppRule(appID: "com.apple.ActivityMonitor", workspace: 3, floats: true),
    ])
    return model
}

@MainActor
func render<ViewContent: View>(
    _ content: ViewContent,
    path: String,
    appearance: NSAppearance.Name
) -> Bool {
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2

    var image: NSImage?
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
        image = renderer.nsImage
    }

    guard let image,
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("render failed: \(path)\n".utf8))
        return false
    }

    do {
        try png.write(to: URL(fileURLWithPath: path))
        print(path)
        return true
    } catch {
        FileHandle.standardError.write(Data("write failed: \(path): \(error)\n".utf8))
        return false
    }
}

@MainActor
func renderHosted<ViewContent: View>(
    _ content: ViewContent,
    size: NSSize,
    path: String,
    appearance: NSAppearance.Name
) -> Bool {
    let hostingController = NSHostingController(rootView: content)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: appearance)
    window.contentViewController = hostingController
    window.setContentSize(size)
    hostingController.view.frame = NSRect(origin: .zero, size: size)
    hostingController.view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    guard let rep = hostingController.view.bitmapImageRepForCachingDisplay(
        in: hostingController.view.bounds
    ) else {
        FileHandle.standardError.write(Data("render failed: \(path)\n".utf8))
        return false
    }
    hostingController.view.cacheDisplay(in: hostingController.view.bounds, to: rep)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("encode failed: \(path)\n".utf8))
        return false
    }

    do {
        try png.write(to: URL(fileURLWithPath: path))
        print(path)
        return true
    } catch {
        FileHandle.standardError.write(Data("write failed: \(path): \(error)\n".utf8))
        return false
    }
}

/// Renders a pane at the size it reports to the settings window, so the
/// PNG also shows whether the pane fits without scrolling.
@MainActor
func renderPane(
    _ pane: SettingsPane,
    model: SettingsModel,
    path: String,
    scheme: ColorScheme,
    appearance: NSAppearance.Name
) -> Bool {
    let selection = AppRuleSelection()
    selection.workspace = ["com.apple.Notes"]
    let view = SettingsPaneView(pane: pane, model: model, actions: .preview, appRuleSelection: selection)
        .environment(\.colorScheme, scheme)
    let probe = NSHostingController(rootView: view)
    let size = probe.sizeThatFits(in: NSSize(width: settingsPaneWidth, height: 10_000))
    return renderHosted(view, size: size, path: path, appearance: appearance)
}

/// Captures the real settings window, toolbar included, to check the chrome
/// and the pane-driven sizing that per-pane renders cannot show.
@MainActor
func renderWindow(path: String, appearance: NSAppearance.Name) -> Bool {
    let controller = SettingsWindowController(
        model: makeSettingsModel(accessibilityGranted: true),
        actions: .preview
    )
    guard let window = controller.window, let frameView = window.contentView?.superview else {
        FileHandle.standardError.write(Data("window unavailable: \(path)\n".utf8))
        return false
    }
    window.appearance = NSAppearance(named: appearance)
    window.orderFront(nil)
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    window.display()

    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
        FileHandle.standardError.write(Data("render failed: \(path)\n".utf8))
        return false
    }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    window.orderOut(nil)

    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print(path)
        return true
    } catch {
        FileHandle.standardError.write(Data("write failed: \(path): \(error)\n".utf8))
        return false
    }
}

@MainActor
func renderAll(into directory: String) -> Bool {
    var ok = true

    try? FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
    )

    for (suffix, scheme, appearance) in [
        ("light", ColorScheme.light, NSAppearance.Name.aqua),
        ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
    ] {
        let status = StatusPreview(statusModel: makeStatusModel(), scheme: scheme)
            .environment(\.colorScheme, scheme)
        // SwiftUI's colorScheme drives Color.background and friends, while
        // NSColor-backed styles resolve against the drawing appearance.
        ok = render(
            status,
            path: "\(directory)/status-\(suffix).png",
            appearance: appearance
        ) && ok
        ok = renderMenu(path: "\(directory)/menu-\(suffix).png", appearance: appearance) && ok
        for pane in SettingsPane.allCases {
            ok = renderPane(
                pane,
                model: makeSettingsModel(accessibilityGranted: true),
                path: "\(directory)/settings-\(pane.rawValue)-\(suffix).png",
                scheme: scheme,
                appearance: appearance
            ) && ok
        }
        ok = renderPane(
            .general,
            model: makeSettingsModel(accessibilityGranted: false),
            path: "\(directory)/settings-permission-required-\(suffix).png",
            scheme: scheme,
            appearance: appearance
        ) && ok
        let failedApply = makeSettingsModel(accessibilityGranted: true)
        failedApply.settings.innerGap = 12
        failedApply.setConfigStatus(succeeded: false, message: "Could not save settings; previous settings kept")
        ok = renderPane(
            .tiling,
            model: failedApply,
            path: "\(directory)/settings-apply-failed-\(suffix).png",
            scheme: scheme,
            appearance: appearance
        ) && ok
        ok = renderWindow(
            path: "\(directory)/settings-window-\(suffix).png",
            appearance: appearance
        ) && ok
    }

    return ok
}

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
exit(MainActor.assumeIsolated { renderAll(into: directory) } ? 0 : 1)
