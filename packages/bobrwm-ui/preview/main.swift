// Offscreen render of the real menu bar views.
//
// `zig build ui-preview` writes light and dark PNGs so the menu can be
// iterated on without rebuilding bobrwm and interrupting a running window
// manager. This links MenuRow.swift directly, so what it renders is what
// ships; only the surrounding menu chrome is faked, since ImageRenderer
// cannot reproduce AppKit's vibrancy.

import AppKit
import BobrwmUIABI
import SwiftUI

struct Sample {
    let id: UInt8
    let name: String
    let shortcut: String?
    let count: UInt32
    var isActive = false
    var isFocused = false
    var isHighlighted = false
}

let samples: [Sample] = [
    .init(id: 1, name: "term", shortcut: "⌥1", count: 3, isActive: true, isFocused: true),
    .init(id: 2, name: "web", shortcut: "⌥2", count: 1, isActive: true),
    .init(id: 3, name: "chat", shortcut: "⌥3", count: 1, isHighlighted: true),
    .init(id: 4, name: "4", shortcut: "⌥4", count: 0),
    .init(id: 5, name: "mail", shortcut: "⌥A", count: 1),
    .init(id: 6, name: "music", shortcut: "⌥S", count: 2),
    .init(id: 7, name: "7", shortcut: "⌥D", count: 12),
]

let sampleApplications: [UInt8: [String]] = [
    1: ["Ghostty", "Neovim"],
    2: ["Safari"],
    3: ["Messages"],
    5: ["Mail"],
    6: ["Music"],
    7: ["Finder", "Preview", "Xcode"],
]

func rowState(_ sample: Sample) -> RowState {
    let state = RowState()
    state.windowCount = sample.count
    state.isActive = sample.isActive
    state.isFocused = sample.isFocused
    state.isHighlighted = sample.isHighlighted
    return state
}

func actionState(highlighted: Bool = false) -> RowState {
    let state = RowState()
    state.isHighlighted = highlighted
    return state
}

/// Display order can differ from numeric workspace order.
func makeStatusModel() -> StatusModel {
    let model = StatusModel()
    model.chips = samples.filter(\.isActive).reversed().map { sample in
        .init(
            id: sample.id,
            label: sample.shortcut.map(shortcutKeyLabel) ?? "\(sample.id)",
            name: sample.name == "\(sample.id)" ? "" : sample.name,
            isFocused: sample.isFocused
        )
    }
    return model
}

struct MenuPreview: View {
    let statusModel: StatusModel
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusBarView(model: statusModel)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Workspaces")

                ForEach(samples, id: \.id) { sample in
                    WorkspaceRow(
                        state: rowState(sample),
                        id: sample.id,
                        name: sample.name,
                        shortcut: sample.shortcut
                    )
                }

                divider
                ActionRow(state: actionState(), title: "Previous Workspace", shortcut: "⌃←")
                ActionRow(state: actionState(), title: "Next Workspace", shortcut: "⌃→")

                divider
                ActionRow(state: actionState(), title: "Retile")
                ActionRow(state: actionState(), title: "Reload Config")
                ActionRow(state: actionState(highlighted: true), title: "Open Config File")

                divider
                ActionRow(state: actionState(), title: "Settings…", shortcut: "⌘,")

                divider
                ActionRow(state: actionState(), title: "Quit bobrwm")
            }
            .padding(.vertical, 5)
            .frame(width: 250)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
        }
        .padding(20)
        // Opaque: a transparent render composites against whatever the viewer
        // uses, which makes outlined chips look like they failed to draw.
        .background(scheme == .dark ? Color.black : Color(white: 0.96))
    }

    private var divider: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 4)
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
        let menu = MenuPreview(statusModel: makeStatusModel(), scheme: scheme)
            .environment(\.colorScheme, scheme)
        // SwiftUI's colorScheme drives Color.background and friends, while
        // NSColor-backed styles resolve against the drawing appearance.
        ok = render(
            menu,
            path: "\(directory)/menu-\(suffix).png",
            appearance: appearance
        ) && ok
        for section in SettingsSection.allCases {
            let settings = SettingsView(
                model: makeSettingsModel(accessibilityGranted: true),
                actions: .preview,
                initialSection: section
            )
            .frame(width: 780, height: 560)
            .environment(\.colorScheme, scheme)

            ok = renderHosted(
                settings,
                size: NSSize(width: 780, height: 560),
                path: "\(directory)/settings-\(section.rawValue)-\(suffix).png",
                appearance: appearance
            ) && ok
        }

        let permissionRequired = SettingsView(
            model: makeSettingsModel(accessibilityGranted: false),
            actions: .preview,
            initialSection: .general
        )
        .frame(width: 780, height: 560)
        .environment(\.colorScheme, scheme)
        ok = renderHosted(
            permissionRequired,
            size: NSSize(width: 780, height: 560),
            path: "\(directory)/settings-permission-required-\(suffix).png",
            appearance: appearance
        ) && ok
    }

    return ok
}

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
exit(MainActor.assumeIsolated { renderAll(into: directory) } ? 0 : 1)
