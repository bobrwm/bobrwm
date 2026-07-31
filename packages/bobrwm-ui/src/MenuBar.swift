import AppKit
import BobrwmUIABI
import SwiftUI

final class MenuBarController: NSObject, NSMenuDelegate {
    struct Workspace {
        let id: UInt8
        let name: String
        let windowCount: UInt32
        let isFocused: Bool
    }

    private let callbacks: BWMenuBarCallbacks
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var workspaces: [Workspace] = []
    private var workspaceItemsByID: [UInt8: RowItem] = [:]

    init(callbacks: BWMenuBarCallbacks) {
        self.callbacks = callbacks
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
    }

    func tearDown() {
        menu.delegate = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func setWorkspaces(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
        rebuild()
    }

    func setActiveWorkspaces(_ ids: Set<UInt8>) {
        for (id, item) in workspaceItemsByID {
            let isFocused = ids.contains(id)
            if item.rowState.isFocused != isFocused {
                item.rowState.isFocused = isFocused
            }
        }
    }

    func setTitle(_ title: String) {
        statusItem.button?.title = title
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

        addAction("Retile", #selector(retile))
        addAction("Open Config File", #selector(openConfig))
        menu.addItem(.separator())

        for workspace in workspaces {
            addWorkspace(workspace)
        }

        addAction("Previous Workspace", #selector(previousWorkspace))
        addAction("Next Workspace", #selector(nextWorkspace))
        menu.addItem(.separator())

        addAction("Quit bobrwm", #selector(quit))
    }

    private func addAction(_ title: String, _ action: Selector) {
        let item = RowItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.view = MenuRowHostView(rootView: ActionRow(state: item.rowState, title: title))
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
        item.rowState.isFocused = workspace.isFocused
        item.view = MenuRowHostView(
            rootView: WorkspaceRow(
                state: item.rowState,
                id: workspace.id,
                name: workspace.name,
                windowCount: workspace.windowCount
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
public func menuBarSetWorkspaces(_ rows: UnsafePointer<BWWorkspaceRow>?, _ count: Int) {
    guard let controller else { return }

    let buffer = UnsafeBufferPointer(start: rows, count: count)
    controller.setWorkspaces(buffer.map { row in
        .init(
            id: row.id,
            name: row.name.map { String(cString: $0) } ?? "",
            windowCount: row.window_count,
            isFocused: row.is_focused
        )
    })
}

@_cdecl("bw_menubar_set_active_workspaces")
public func menuBarSetActiveWorkspaces(_ ids: UnsafePointer<UInt8>?, _ count: Int) {
    guard let controller else { return }

    let buffer = UnsafeBufferPointer(start: ids, count: count)
    controller.setActiveWorkspaces(Set(buffer))
}

@_cdecl("bw_menubar_set_title")
public func menuBarSetTitle(_ title: UnsafePointer<CChar>?) {
    guard let controller, let title else { return }
    controller.setTitle(String(cString: title))
}
