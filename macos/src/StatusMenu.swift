import AppKit
import SwiftUI

/// Actions the status menu sends. An @objc protocol rather than the controller
/// itself so the preview harness can build the same menu without the core.
@objc protocol StatusMenuActions: AnyObject {
    func switchToWorkspace(_ sender: NSMenuItem)
    func retile(_ sender: NSMenuItem)
    func reloadConfig(_ sender: NSMenuItem)
    func openConfig(_ sender: NSMenuItem)
    func showAbout(_ sender: NSMenuItem)
    func showSettings(_ sender: NSMenuItem)
    func quit(_ sender: NSMenuItem)
}

final class StatusMenu {
    private struct RowState: Equatable {
        let isFocused: Bool
        let isActive: Bool
        let windowCount: UInt32

        init(_ workspace: WorkspaceInfo) {
            isFocused = workspace.isFocused
            isActive = workspace.isActive
            windowCount = workspace.windowCount
        }
    }

    let menu = NSMenu()
    private var workspaceItems: [UInt8: NSMenuItem] = [:]
    private var rowStates: [UInt8: RowState] = [:]
    private var countTab = NSTextTab(textAlignment: .right, location: 0)

    init() {
        menu.autoenablesItems = false
        menu.showsStateColumn = false
    }

    func rebuild(workspaces: [WorkspaceInfo], target: StatusMenuActions) {
        menu.removeAllItems()
        workspaceItems.removeAll(keepingCapacity: true)
        rowStates.removeAll(keepingCapacity: true)
        countTab = Self.countTab(for: workspaces)

        if !workspaces.isEmpty {
            menu.addItem(.sectionHeader(title: "Workspaces"))
            for workspace in workspaces {
                let item = addItem(
                    workspace.label,
                    #selector(StatusMenuActions.switchToWorkspace(_:)),
                    workspace.shortcut,
                    target
                )
                item.tag = Int(workspace.id)
                if #available(macOS 27, *) {
                    item.preferredImageVisibility = .visible
                }
                workspaceItems[workspace.id] = item
                update(item, workspace)
            }

            menu.addItem(.separator())
        }

        addItem("Retile", #selector(StatusMenuActions.retile(_:)), nil, target)
        addItem("Reload Config", #selector(StatusMenuActions.reloadConfig(_:)), nil, target)
        addItem("Open Config File", #selector(StatusMenuActions.openConfig(_:)), nil, target)
        menu.addItem(.separator())

        addItem("About BobrWM", #selector(StatusMenuActions.showAbout(_:)), nil, target)
        addItem(
            "Settings…",
            #selector(StatusMenuActions.showSettings(_:)),
            .init(key: ",", modifiers: .command),
            target
        )
        menu.addItem(.separator())

        addItem(
            "Quit BobrWM",
            #selector(StatusMenuActions.quit(_:)),
            .init(key: "q", modifiers: .command),
            target
        )
    }

    func update(_ workspaces: [WorkspaceInfo]) {
        for workspace in workspaces {
            guard let item = workspaceItems[workspace.id] else { continue }
            update(item, workspace)
        }
    }

    private func update(_ item: NSMenuItem, _ workspace: WorkspaceInfo) {
        let state = RowState(workspace)
        guard rowStates[workspace.id] != state else { return }
        rowStates[workspace.id] = state

        item.image = WorkspaceBadge.image(for: workspace)

        let font = NSFont.menuFont(ofSize: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [countTab]
        let title = NSMutableAttributedString(
            string: workspace.label,
            attributes: [
                .font: font,
                .foregroundColor: workspace.hasName
                    ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )

        title.append(
            NSAttributedString(
                string: "\t" + (workspace.windowCount == 0 ? "—" : "\(workspace.windowCount)"),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: font.pointSize, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        item.attributedTitle = title
    }

    private static func countTab(for workspaces: [WorkspaceInfo]) -> NSTextTab {
        let font = NSFont.menuFont(ofSize: 0)
        let widest =
            workspaces
            .map { NSAttributedString(string: $0.label, attributes: [.font: font]).size().width }
            .max() ?? 0
        return NSTextTab(textAlignment: .right, location: ceil(widest) + 40)
    }

    @discardableResult
    private func addItem(
        _ title: String,
        _ action: Selector,
        _ shortcut: Shortcut?,
        _ target: StatusMenuActions
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        if let shortcut {
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(item)
        return item
    }
}

/// Letters and digits read as text; every other key is an SF Symbol.
enum KeyLabel: Equatable {
    case text(String)
    case symbol(String)
}

// Never shown for an accessory app, but its key equivalents still reach the
// Settings window: without it, Copy, Paste, Undo, and Close do nothing there.
enum MainMenu {
    static func make(target: StatusMenuActions) -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, "BobrWM")
        app.addItem(item("About BobrWM", #selector(StatusMenuActions.showAbout(_:)), "", target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(StatusMenuActions.showSettings(_:)), ",", target))
        app.addItem(.separator())
        let services = submenu(of: app, "Services")
        NSApplication.shared.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item("Hide BobrWM", #selector(NSApplication.hide(_:)), "h"))
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Quit BobrWM", #selector(StatusMenuActions.quit(_:)), "q", target))

        let edit = submenu(of: main, "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        let redo = item("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        let window = submenu(of: main, "Window")
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        NSApplication.shared.windowsMenu = window

        return main
    }

    private static func submenu(of parent: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    // A nil target sends the action down the responder chain.
    private static func item(
        _ title: String, _ action: Selector, _ key: String, _ target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

struct Shortcut {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    private static let namedKeys: [String: (equivalent: String, symbol: String)] = [
        "return": ("\r", "return"),
        "tab": ("\t", "arrow.right.to.line"),
        "space": (" ", "space"),
        "delete": ("\u{8}", "delete.left"),
        "escape": ("\u{1b}", "escape"),
        "left": (functionKey(.leftArrow), "arrow.left"),
        "right": (functionKey(.rightArrow), "arrow.right"),
        "up": (functionKey(.upArrow), "arrow.up"),
        "down": (functionKey(.downArrow), "arrow.down"),
    ]

    var keyEquivalent: String {
        Self.namedKeys[key]?.equivalent ?? key.lowercased()
    }

    var keyLabel: KeyLabel {
        Self.namedKeys[key].map { .symbol($0.symbol) } ?? .text(key.uppercased())
    }

    var modifierSymbols: [String] {
        let symbols: [(NSEvent.ModifierFlags, String)] = [
            (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command"),
        ]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1)
    }

    private static func functionKey(_ key: NSEvent.SpecialKey) -> String {
        String(Character(UnicodeScalar(UInt32(key.rawValue))!))
    }
}

extension WorkspaceInfo {
    var keyLabel: KeyLabel {
        shortcut?.keyLabel ?? .text("\(id)")
    }
}

struct KeyLabelView: View {
    let label: KeyLabel

    var body: some View {
        switch label {
        case .text(let text): Text(text).monospacedDigit()
        case .symbol(let name): Image(systemName: name)
        }
    }
}

struct ShortcutView: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 1) {
            ForEach(shortcut.modifierSymbols, id: \.self) { Image(systemName: $0) }
            KeyLabelView(label: shortcut.keyLabel)
        }
    }
}

enum WorkspaceBadge {
    static func image(for workspace: WorkspaceInfo) -> NSImage {
        let label = workspace.keyLabel
        let isFocused = workspace.isFocused
        let isVisible = workspace.isActive && !isFocused

        // A template, so AppKit tints it for the appearance and the highlight;
        // alpha carries the focused, visible, and idle states.
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            if isVisible {
                NSColor.black.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                NSColor.black.withAlphaComponent(isFocused ? 0.18 : 0.06).setFill()
                path.fill()
            }

            let weight: NSFont.Weight = isFocused ? .semibold : .medium
            let alpha: CGFloat = workspace.isActive ? 1 : 0.5
            switch label {
            case .text(let string):
                let text = NSAttributedString(
                    string: string,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight),
                        .foregroundColor: NSColor.black.withAlphaComponent(alpha),
                    ])
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            case .symbol(let name):
                guard
                    let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 9, weight: weight))
                else { break }
                let size = symbol.size
                symbol.draw(
                    in: NSRect(
                        x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                        width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: alpha)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isFocused ? "Focused" : isVisible ? "Visible" : nil
        return image
    }
}

final class StatusModel: ObservableObject {
    struct Chip: Identifiable {
        let id: UInt8
        let label: KeyLabel
        let name: String
        let isFocused: Bool

        init(_ workspace: WorkspaceInfo) {
            id = workspace.id
            label = workspace.keyLabel
            name = workspace.hasName ? workspace.name : ""
            isFocused = workspace.isFocused
        }
    }

    @Published var chips: [Chip] = []
    @Published var message: String?
}

struct StatusBarView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if let message = model.message {
                Text(message).font(.system(size: 13))
            } else {
                HStack(spacing: 3) {
                    ForEach(model.chips) { chip in
                        StatusChip(chip: chip)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}

private struct StatusChip: View {
    let chip: StatusModel.Chip

    var body: some View {
        HStack(spacing: 4) {
            KeyLabelView(label: chip.label)
                .foregroundStyle(.secondary)

            if !chip.name.isEmpty {
                Text(chip.name)
            }
        }
        .font(.system(size: 13, weight: chip.isFocused ? .semibold : .regular))
        .frame(minHeight: 16)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(chip.isFocused ? 0.14 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            chip.isFocused ? .clear : Color.primary.opacity(0.25),
                            lineWidth: 1
                        )
                }
        }
    }
}

final class StatusBarHostingView: NSHostingView<StatusBarView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
