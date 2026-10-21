import AppKit
import BobrwmUIABI
import SwiftUI

final class MenuBarController: NSObject, StatusMenuActions {
    private let callbacks: BWMenuBarCallbacks
    private let settingsModel: SettingsModel
    private let settingsWindow: SettingsWindowController
    private let statusItem: NSStatusItem
    private let statusMenu = StatusMenu()
    private let statusModel = StatusModel()
    private let statusView: StatusBarHostingView

    private var applicationNamesByProcessID: [Int32: String] = [:]

    init(callbacks: BWMenuBarCallbacks, configPath: String?) {
        self.callbacks = callbacks
        let model = SettingsModel(configPath: configPath)
        settingsModel = model
        settingsWindow = SettingsWindowController(
            model: model,
            actions: SettingsActions(callbacks: callbacks)
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusView = StatusBarHostingView(rootView: StatusBarView(model: statusModel))
        super.init()

        statusItem.menu = statusMenu.menu

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
        settingsWindow.close()
        statusItem.menu = nil
        statusView.removeFromSuperview()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func setWorkspaces(_ workspaces: [WorkspaceInfo]) {
        settingsModel.setWorkspaces(workspaces)
        rebuild()
    }

    func setState(_ rawStates: UnsafeBufferPointer<BWWorkspaceState>) {
        let previousNames = applicationNamesByProcessID
        var currentNames: [Int32: String] = [:]
        var states: [UInt8: WorkspaceRuntimeState] = [:]
        currentNames.reserveCapacity(previousNames.count)
        states.reserveCapacity(rawStates.count)

        for state in rawStates {
            let processIDs = UnsafeBufferPointer(
                start: state.process_ids,
                count: state.process_count
            )
            var applicationNames: [String] = []
            applicationNames.reserveCapacity(processIDs.count)
            for processID in processIDs {
                let name = previousNames[processID] ?? applicationName(processID)
                currentNames[processID] = name
                if !applicationNames.contains(name) {
                    applicationNames.append(name)
                }
            }
            applicationNames.sort {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            states[state.id] = .init(
                applicationNames: applicationNames,
                windowCount: state.window_count,
                isActive: state.is_active,
                isFocused: state.is_focused,
                displayOrder: state.display_order
            )
        }
        applicationNamesByProcessID = currentNames

        statusModel.message = nil
        settingsModel.setWorkspaceStates(states)
        statusMenu.update(settingsModel.workspaces)

        statusModel.chips = settingsModel.workspaces
            .filter(\.isActive)
            .sorted {
                let leftOrder = states[$0.id]?.displayOrder ?? UInt8.max
                let rightOrder = states[$1.id]?.displayOrder ?? UInt8.max
                return leftOrder == rightOrder ? $0.id < $1.id : leftOrder < rightOrder
            }
            .map(StatusModel.Chip.init)

        scheduleResize()
    }

    func setMessage(_ message: String) {
        statusModel.message = message
        scheduleResize()
    }

    func setConfigStatus(succeeded: Bool, message: String) {
        settingsModel.setConfigStatus(succeeded: succeeded, message: message)
    }

    func showSettingsIfPermissionRequired() {
        settingsModel.refreshAccessibility()
        if !settingsModel.accessibilityGranted {
            settingsWindow.show(pane: .general)
        }
    }

    func setSettings(_ settings: BWSettings) {
        settingsModel.setSettings(settings)
    }

    private func applicationName(_ processID: Int32) -> String {
        let application = NSRunningApplication(processIdentifier: processID)
        return application?.localizedName
            ?? application?.bundleIdentifier
            ?? "PID \(processID)"
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

    /// Builds from the settings model's copy, which carries the last runtime
    /// state over, so a config reload does not blank the rows until the next
    /// state push.
    private func rebuild() {
        statusMenu.rebuild(workspaces: settingsModel.workspaces, target: self)
    }

    func retile(_ sender: NSMenuItem) { callbacks.retile() }
    func reloadConfig(_ sender: NSMenuItem) { _ = callbacks.reload_config() }
    func openConfig(_ sender: NSMenuItem) { callbacks.open_config() }
    func showSettings(_ sender: NSMenuItem) { settingsWindow.show() }

    // An accessory app is never frontmost, so the panel would open behind
    // the current app without activating first.
    func showAbout(_ sender: NSMenuItem) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }
    func quit(_ sender: NSMenuItem) { callbacks.quit() }

    func switchToWorkspace(_ sender: NSMenuItem) {
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
public func menuBarInit(
    _ callbacks: BWMenuBarCallbacks,
    _ configPath: UnsafePointer<CChar>?
) {
    guard controller == nil else { return }
    controller = MenuBarController(callbacks: callbacks, configPath: borrowedString(configPath))
    DispatchQueue.main.async {
        controller?.showSettingsIfPermissionRequired()
    }
}

@_cdecl("bw_menubar_deinit")
public func menuBarDeinit() {
    controller?.tearDown()
    controller = nil
}

private func shortcut(_ row: BWWorkspace) -> Shortcut? {
    guard let key = borrowedString(row.shortcut_key) else { return nil }

    let raw = row.shortcut_modifiers
    var modifiers: NSEvent.ModifierFlags = []
    if raw.control { modifiers.insert(.control) }
    if raw.option { modifiers.insert(.option) }
    if raw.shift { modifiers.insert(.shift) }
    if raw.command { modifiers.insert(.command) }
    return Shortcut(key: key, modifiers: modifiers)
}

@_cdecl("bw_menubar_set_workspaces")
public func menuBarSetWorkspaces(
    _ rows: UnsafePointer<BWWorkspace>?,
    _ count: Int
) {
    guard let controller else { return }

    let buffer = UnsafeBufferPointer(start: rows, count: count)
    controller.setWorkspaces(buffer.map { row in
        .init(
            id: row.id,
            name: borrowedString(row.name) ?? "",
            shortcut: shortcut(row)
        )
    })
}

@_cdecl("bw_menubar_set_state")
public func menuBarSetState(_ states: UnsafePointer<BWWorkspaceState>?, _ count: Int) {
    guard let controller else { return }

    let buffer = UnsafeBufferPointer(start: states, count: count)
    controller.setState(buffer)
}

@_cdecl("bw_menubar_set_settings")
public func menuBarSetSettings(_ settings: BWSettings) {
    controller?.setSettings(settings)
}

@_cdecl("bw_menubar_set_message")
public func menuBarSetMessage(_ message: UnsafePointer<CChar>?) {
    guard let controller, let message = borrowedString(message) else { return }
    controller.setMessage(message)
}

@_cdecl("bw_menubar_set_config_status")
public func menuBarSetConfigStatus(_ succeeded: Bool, _ message: UnsafePointer<CChar>?) {
    guard let controller, let message = borrowedString(message) else { return }
    controller.setConfigStatus(succeeded: succeeded, message: message)
}
