import AppKit
import BobrwmUIABI
import SwiftUI

final class MenuBarController: NSObject, NSMenuDelegate {
    struct Workspace {
        let id: UInt8
        let name: String
        let shortcut: String?
    }

    struct ActionShortcuts {
        var previousWorkspace: String?
        var nextWorkspace: String?
    }

    private let callbacks: BWMenuBarCallbacks
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusModel = StatusModel()
    private let statusView: StatusBarHostingView

    private var workspaces: [Workspace] = []
    private var shortcuts = ActionShortcuts()
    private var workspaceItemsByID: [UInt8: RowItem] = [:]

    init(callbacks: BWMenuBarCallbacks) {
        self.callbacks = callbacks
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusView = StatusBarHostingView(rootView: StatusBarView(model: statusModel))
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if let button = statusItem.button {
            button.title = ""
            // Deliberately not constrained to the button: the button's width
            // comes from statusItem.length, which is set from this view's
            // fitting size, so pinning the edges would feed that back into
            // itself and the measured width would only ever grow.
            statusView.translatesAutoresizingMaskIntoConstraints = true
            statusView.sizingOptions = [.intrinsicContentSize]
            button.addSubview(statusView)
        }

        rebuild()
    }

    func tearDown() {
        menu.delegate = nil
        statusItem.menu = nil
        statusView.removeFromSuperview()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func setWorkspaces(_ workspaces: [Workspace], shortcuts: ActionShortcuts) {
        self.workspaces = workspaces
        self.shortcuts = shortcuts
        rebuild()
    }

    func setState(_ states: [UInt8: BWWorkspaceState]) {
        statusModel.message = nil

        for (id, item) in workspaceItemsByID {
            let state = states[id]
            item.rowState.windowCount = state?.window_count ?? 0
            item.rowState.isActive = state?.is_active ?? false
            item.rowState.isFocused = state?.is_focused ?? false
        }

        // Only what is on screen: one chip per display, not the whole list.
        statusModel.chips = workspaces.compactMap { workspace in
            guard let state = states[workspace.id], state.is_active else { return nil }
            let hasName = !workspace.name.isEmpty && workspace.name != "\(workspace.id)"
            return .init(
                id: workspace.id,
                label: workspace.shortcut.map(shortcutKeyLabel) ?? "\(workspace.id)",
                name: hasName ? workspace.name : "",
                isFocused: state.is_focused
            )
        }

        scheduleResize()
    }

    func setMessage(_ message: String) {
        statusModel.message = message
        scheduleResize()
    }

    /// NSStatusItem does not track a hosted view's intrinsic size, so both the
    /// item length and the view's own frame have to be pushed back after every
    /// content change.
    ///
    /// Deferred by one runloop turn on purpose: NSHostingView applies model
    /// changes asynchronously, so measuring inline reports the *previous*
    /// content's width and SwiftUI truncates the chips to fit it.
    private func scheduleResize() {
        DispatchQueue.main.async { [weak self] in
            self?.resizeStatusItem()
        }
    }

    private func resizeStatusItem() {
        statusView.layoutSubtreeIfNeeded()

        let width = statusView.fittingSize.width
        guard width > 0 else { return }

        statusView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: NSStatusBar.system.thickness
        )
        statusItem.length = width
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for case let row as RowItem in menu.items {
            let isHighlighted = row === item
            if row.rowState.isHighlighted != isHighlighted {
                row.rowState.isHighlighted = isHighlighted
            }
        }
    }

    // Rebuild the entire menu from scratch when the controller's state changes.
    private func rebuild() {
        menu.removeAllItems()
        workspaceItemsByID.removeAll(keepingCapacity: true)

        if !workspaces.isEmpty {
            addHeader("Workspaces")
            for workspace in workspaces {
                addWorkspace(workspace)
            }
            menu.addItem(.separator())
        }

        addAction("Previous Workspace", #selector(previousWorkspace), shortcuts.previousWorkspace)
        addAction("Next Workspace", #selector(nextWorkspace), shortcuts.nextWorkspace)
        menu.addItem(.separator())

        addAction("Retile", #selector(retile), nil)
        addAction("Open Config File", #selector(openConfig), nil)
        menu.addItem(.separator())

        addAction("Quit bobrwm", #selector(quit), nil)
    }

    // Not a RowItem, so menu(_:willHighlight:) skips it and it never lights up.
    private func addHeader(_ title: String) {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = MenuRowHostView(rootView: SectionHeader(title: title))
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector, _ shortcut: String?) {
        let item = RowItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.view = MenuRowHostView(
            rootView: ActionRow(state: item.rowState, title: title, shortcut: shortcut)
        )
        menu.addItem(item)
    }

    private func addWorkspace(_ workspace: Workspace) {
        let item = RowItem(
            title: workspace.name,
            action: #selector(switchToWorkspace(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = Int(workspace.id)
        item.view = MenuRowHostView(
            rootView: WorkspaceRow(
                state: item.rowState,
                id: workspace.id,
                name: workspace.name,
                shortcut: workspace.shortcut
            )
        )

        menu.addItem(item)
        workspaceItemsByID[workspace.id] = item
    }

    @objc private func retile() { callbacks.retile() }
    @objc private func openConfig() { callbacks.open_config() }
    @objc private func previousWorkspace() { callbacks.previous_workspace() }
    @objc private func nextWorkspace() { callbacks.next_workspace() }
    @objc private func quit() { callbacks.quit() }

    @objc private func switchToWorkspace(_ sender: NSMenuItem) {
        guard sender.tag > 0, sender.tag <= Int(UInt8.max) else { return }
        callbacks.switch_to_workspace(UInt8(sender.tag))
    }
}

/// Every entry point runs on the main thread: the window manager calls them
/// from its own AppKit main thread, never from the AX observer thread.
private var controller: MenuBarController?

private func borrowedString(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let value = String(cString: pointer)
    return value.isEmpty ? nil : value
}

@_cdecl("bw_menubar_init")
public func menuBarInit(_ callbacks: BWMenuBarCallbacks) {
    guard controller == nil else { return }
    controller = MenuBarController(callbacks: callbacks)
}

@_cdecl("bw_menubar_deinit")
public func menuBarDeinit() {
    controller?.tearDown()
    controller = nil
}

@_cdecl("bw_menubar_set_workspaces")
public func menuBarSetWorkspaces(
    _ rows: UnsafePointer<BWWorkspace>?,
    _ count: Int,
    _ shortcuts: BWActionShortcuts
) {
    guard let controller else { return }

    let buffer = UnsafeBufferPointer(start: rows, count: count)
    controller.setWorkspaces(
        buffer.map { row in
            .init(
                id: row.id,
                name: borrowedString(row.name) ?? "",
                shortcut: borrowedString(row.shortcut)
            )
        },
        shortcuts: .init(
            previousWorkspace: borrowedString(shortcuts.previous_workspace),
            nextWorkspace: borrowedString(shortcuts.next_workspace)
        )
    )
}

@_cdecl("bw_menubar_set_state")
public func menuBarSetState(_ states: UnsafePointer<BWWorkspaceState>?, _ count: Int) {
    guard let controller else { return }

    let buffer = UnsafeBufferPointer(start: states, count: count)
    controller.setState(Dictionary(uniqueKeysWithValues: buffer.map { ($0.id, $0) }))
}

@_cdecl("bw_menubar_set_message")
public func menuBarSetMessage(_ message: UnsafePointer<CChar>?) {
    guard let controller, let message = borrowedString(message) else { return }
    controller.setMessage(message)
}
