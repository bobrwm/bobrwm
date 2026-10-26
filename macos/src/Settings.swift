import AppKit
import ApplicationServices
import BobrwmUIABI
import Combine
import SwiftUI

struct WorkspaceInfo: Identifiable {
    let id: UInt8
    let name: String
    let shortcut: Shortcut?
    var applicationNames: [String] = []
    var windowCount: UInt32 = 0
    var isActive = false
    var isFocused = false

    var hasName: Bool {
        !name.isEmpty && name != "\(id)"
    }

    var label: String {
        hasName ? name : "Workspace \(id)"
    }
}

struct WorkspaceRuntimeState {
    let applicationNames: [String]
    let windowCount: UInt32
    let isActive: Bool
    let isFocused: Bool
    let displayOrder: UInt8
}

enum LayoutSetting: UInt8, CaseIterable, Identifiable {
    case bsp
    case monocle
    var id: Self { self }
    var title: String { self == .bsp ? "BSP" : "Monocle" }
}

enum SplitSetting: UInt8, CaseIterable, Identifiable {
    case automatic
    case horizontal
    case vertical
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }
}

enum InsertionPointSetting: UInt8, CaseIterable, Identifiable {
    case focused
    case first
    case last
    case minimumDepth
    var id: Self { self }
    var title: String {
        switch self {
        case .focused: "Focused window"
        case .first: "First window"
        case .last: "Last window"
        case .minimumDepth: "Shallowest split"
        }
    }
}

enum NewWindowPositionSetting: UInt8, CaseIterable, Identifiable {
    case first
    case second
    var id: Self { self }
    var title: String { self == .first ? "Left or top" : "Right or bottom" }
}

enum EasingSetting: UInt8, CaseIterable, Identifiable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case spring
    var id: Self { self }
    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease in"
        case .easeOut: "Ease out"
        case .easeInOut: "Ease in and out"
        case .spring: "Spring"
        }
    }
}

struct EditableSettings: Equatable {
    var layout: LayoutSetting = .bsp
    var split: SplitSetting = .automatic
    var insertionPoint: InsertionPointSetting = .focused
    var splitRatio = 0.5
    var newWindowPosition: NewWindowPositionSetting = .second
    var dimmingEnabled = false
    var dimmingLevel = 0.35
    var innerGap: UInt16 = 0
    var outerGapLeft: UInt16 = 0
    var outerGapRight: UInt16 = 0
    var outerGapTop: UInt16 = 0
    var outerGapBottom: UInt16 = 0
    var animationEnabled = false
    var animationDurationMilliseconds: UInt64 = 200
    var easing: EasingSetting = .easeOut
    var startAtLogin = false
    var focusFollowsMouse = false
    var swipeEnabled = false
    var swipeReversed = false
    var followAppResizes = false
    var autoReloadConfig = false

    init() {}

    init(_ raw: BWSettings) {
        layout = LayoutSetting(rawValue: raw.layout) ?? .bsp
        split = SplitSetting(rawValue: raw.bsp_split) ?? .automatic
        insertionPoint = InsertionPointSetting(rawValue: raw.bsp_insert_point) ?? .focused
        splitRatio = raw.bsp_split_ratio
        newWindowPosition = NewWindowPositionSetting(rawValue: raw.new_window_split) ?? .second
        dimmingEnabled = raw.dimming_enabled
        dimmingLevel = Double(raw.dimming_level)
        innerGap = raw.inner_gap
        outerGapLeft = raw.outer_gap_left
        outerGapRight = raw.outer_gap_right
        outerGapTop = raw.outer_gap_top
        outerGapBottom = raw.outer_gap_bottom
        animationEnabled = raw.animation_enabled
        animationDurationMilliseconds = raw.animation_duration_ms
        easing = EasingSetting(rawValue: raw.animation_easing) ?? .easeOut
        startAtLogin = raw.start_at_login
        focusFollowsMouse = raw.focus_follows_mouse
        swipeEnabled = raw.swipe_enabled
        swipeReversed = raw.swipe_reverse
        followAppResizes = raw.follow_app_resizes
        autoReloadConfig = raw.auto_reload_config
    }

    var abiValue: BWSettings {
        BWSettings(
            layout: layout.rawValue,
            bsp_split: split.rawValue,
            bsp_insert_point: insertionPoint.rawValue,
            bsp_split_ratio: splitRatio,
            new_window_split: newWindowPosition.rawValue,
            dimming_enabled: dimmingEnabled,
            dimming_level: Float(dimmingLevel),
            inner_gap: innerGap,
            outer_gap_left: outerGapLeft,
            outer_gap_right: outerGapRight,
            outer_gap_top: outerGapTop,
            outer_gap_bottom: outerGapBottom,
            animation_enabled: animationEnabled,
            animation_duration_ms: animationDurationMilliseconds,
            animation_easing: easing.rawValue,
            start_at_login: startAtLogin,
            focus_follows_mouse: focusFollowsMouse,
            swipe_enabled: swipeEnabled,
            swipe_reverse: swipeReversed,
            follow_app_resizes: followAppResizes,
            auto_reload_config: autoReloadConfig
        )
    }
}

struct AppRule: Identifiable, Equatable {
    let appID: String
    var workspace: UInt8?
    var floats = false

    var id: String { appID }
}

final class SettingsModel: ObservableObject {
    struct ConfigStatus {
        var succeeded: Bool
        var message: String
        var date: Date
    }

    @Published private(set) var workspaces: [WorkspaceInfo] = []
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published var settings = EditableSettings()
    /// The values the core last confirmed. `settings` differs from this only
    /// while an edit is waiting to be applied or after an apply failed.
    @Published private(set) var appliedSettings = EditableSettings()
    @Published var appRules: [AppRule] = []
    @Published private(set) var appliedAppRules: [AppRule] = []
    @Published private(set) var configStatus = ConfigStatus(
        succeeded: true,
        message: "Configuration loaded",
        date: Date()
    )

    let configPath: String?

    init(configPath: String?) {
        self.configPath = configPath
    }

    init(configPath: String?, accessibilityGranted: Bool) {
        self.configPath = configPath
        self.accessibilityGranted = accessibilityGranted
    }

    func setWorkspaces(_ identities: [WorkspaceInfo]) {
        let previous = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        workspaces = identities.map { identity in
            guard let state = previous[identity.id] else { return identity }
            var workspace = identity
            workspace.applicationNames = state.applicationNames
            workspace.windowCount = state.windowCount
            workspace.isActive = state.isActive
            workspace.isFocused = state.isFocused
            return workspace
        }
    }

    func setWorkspaceStates(_ states: [UInt8: WorkspaceRuntimeState]) {
        workspaces = workspaces.map { identity in
            guard let state = states[identity.id] else { return identity }
            var workspace = identity
            workspace.applicationNames = state.applicationNames
            workspace.windowCount = state.windowCount
            workspace.isActive = state.isActive
            workspace.isFocused = state.isFocused
            return workspace
        }
    }

    func setConfigStatus(succeeded: Bool, message: String) {
        configStatus = .init(succeeded: succeeded, message: message, date: Date())
    }

    /// Updates `appliedSettings` first so the settings observer sees the new
    /// value as already applied and does not write it back to the core.
    func setSettings(_ settings: BWSettings) {
        let applied = EditableSettings(settings)
        appliedSettings = applied
        self.settings = applied
    }

    func setAppRules(_ rules: [AppRule]) {
        appliedAppRules = rules
        appRules = rules
    }

    /// True when the last apply was rejected and the shown values no longer
    /// match what is running.
    var applyFailed: Bool {
        !configStatus.succeeded && (settings != appliedSettings || appRules != appliedAppRules)
    }

    func revertSettings() {
        settings = appliedSettings
        appRules = appliedAppRules
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    var diagnostics: String {
        let workspaceSummary = workspaces.map {
            "\($0.id):windows=\($0.windowCount):active=\($0.isActive):focused=\($0.isFocused)"
        }.joined(separator: "\n")
        return """
        BobrWM \(appVersion)
        Accessibility: \(accessibilityGranted ? "granted" : "required")
        Config: \(configPath == nil ? "built-in defaults" : "config.zon")
        Last reload: \(configStatus.succeeded ? "succeeded" : "failed") — \(configStatus.message)
        Workspaces:
        \(workspaceSummary)
        """
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}

struct SettingsActions {
    private let openConfigAction: () -> Void
    private let reloadConfigAction: () -> Void
    private let saveSettingsAction: (EditableSettings) -> Bool
    private let saveAppRulesAction: ([AppRule]) -> Bool
    private let focusWorkspaceAction: (UInt8) -> Void

    init(callbacks: BWMenuBarCallbacks) {
        openConfigAction = { callbacks.open_config() }
        reloadConfigAction = { _ = callbacks.reload_config() }
        saveSettingsAction = { settings in
            var raw = settings.abiValue
            return withUnsafePointer(to: &raw) { callbacks.set_settings($0) }
        }
        saveAppRulesAction = { rules in
            // The C array only borrows these for the call.
            let ids = rules.map { strdup($0.appID) }
            defer { ids.forEach { free($0) } }
            let rows = zip(rules, ids).map { rule, id in
                BWAppRule(app_id: UnsafePointer(id), workspace: rule.workspace ?? 0, floating: rule.floats)
            }
            return rows.withUnsafeBufferPointer { callbacks.set_app_rules($0.baseAddress, $0.count) }
        }
        focusWorkspaceAction = { callbacks.switch_to_workspace($0) }
    }

    private init(
        openConfig: @escaping () -> Void,
        reloadConfig: @escaping () -> Void,
        saveSettings: @escaping (EditableSettings) -> Bool,
        saveAppRules: @escaping ([AppRule]) -> Bool,
        focusWorkspace: @escaping (UInt8) -> Void
    ) {
        openConfigAction = openConfig
        reloadConfigAction = reloadConfig
        saveSettingsAction = saveSettings
        saveAppRulesAction = saveAppRules
        focusWorkspaceAction = focusWorkspace
    }

    static let preview = SettingsActions(
        openConfig: {},
        reloadConfig: {},
        saveSettings: { _ in true },
        saveAppRules: { _ in true },
        focusWorkspace: { _ in }
    )

    func openConfig() { openConfigAction() }
    func reloadConfig() { reloadConfigAction() }
    func saveSettings(_ settings: EditableSettings) -> Bool { saveSettingsAction(settings) }
    func saveAppRules(_ rules: [AppRule]) -> Bool { saveAppRulesAction(rules) }
    func focusWorkspace(_ id: UInt8) { focusWorkspaceAction(id) }

    func revealConfig(path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyDiagnostics(_ diagnostics: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case tiling
    case appearance
    case apps
    case workspaces

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .tiling: "Tiling"
        case .appearance: "Appearance"
        case .apps: "Apps"
        case .workspaces: "Workspaces"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .tiling: "rectangle.split.2x2"
        case .appearance: "paintbrush"
        case .apps: "square.grid.3x3"
        case .workspaces: "rectangle.3.group"
        }
    }
}

/// Fixed so every pane lines up under the toolbar; only the height follows
/// the selected pane, as in other macOS settings windows.
let settingsPaneWidth: CGFloat = 500

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let tabs: SettingsTabViewController
    private var applySubscription: AnyCancellable?
    private var appRulesSubscription: AnyCancellable?

    init(model: SettingsModel, actions: SettingsActions) {
        self.model = model
        tabs = SettingsTabViewController(model: model, actions: actions)

        // HIG: no minimize or zoom for settings windows.
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        restorePosition(of: window)

        // Debounced so dragging a slider or holding a stepper rewrites
        // config.zon once the value settles rather than on every step.
        applySubscription = model.$settings
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak model] settings in
                guard let model, settings != model.appliedSettings else { return }
                _ = actions.saveSettings(settings)
            }
        appRulesSubscription = model.$appRules
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak model] rules in
                guard let model, rules != model.appliedAppRules else { return }
                _ = actions.saveAppRules(rules)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not archivable")
    }

    func show(pane: SettingsPane? = nil) {
        model.refreshAccessibility()
        if let pane { tabs.select(pane) }
        showWindow(nil)
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // Only the top-left is restored; the selected pane decides the height.
    private func restorePosition(of window: NSWindow) {
        let size = window.frame.size
        if window.setFrameUsingName(Self.frameName) {
            let top = window.frame.maxY
            window.setFrame(
                NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height),
                display: false)
        } else {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    private static let frameName = "Settings"

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshAccessibility()
    }
}

final class SettingsTabViewController: NSTabViewController {
    private static let selectedPaneKey = "SettingsSelectedPane"

    init(model: SettingsModel, actions: SettingsActions) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true

        for pane in SettingsPane.allCases {
            let host = NSHostingController(
                rootView: SettingsPaneView(pane: pane, model: model, actions: actions)
            )
            host.sizingOptions = [.preferredContentSize]
            host.title = pane.title

            let item = NSTabViewItem(viewController: host)
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(
                systemSymbolName: pane.symbolName,
                accessibilityDescription: pane.title
            )
            addTabViewItem(item)
        }

        let saved = UserDefaults.standard.string(forKey: Self.selectedPaneKey)
        select(saved.flatMap(SettingsPane.init(rawValue:)) ?? .general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsTabViewController is not archivable")
    }

    func select(_ pane: SettingsPane) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let identifier = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(identifier, forKey: Self.selectedPaneKey)
        }
    }

    // The tab controller snaps the window to the new size; animate it instead.
    override func transition(
        from fromViewController: NSViewController,
        to toViewController: NSViewController,
        options: NSViewController.TransitionOptions = [],
        completionHandler completion: (() -> Void)? = nil
    ) {
        guard let window = view.window, window.isVisible else {
            super.transition(
                from: fromViewController, to: toViewController,
                options: options, completionHandler: completion)
            return
        }

        let content = NSRect(origin: .zero, size: toViewController.preferredContentSize)
        let target = window.frameRect(forContentRect: content)
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size

        // Reduce Motion keeps the crossfade but snaps the size.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window.animationResizeTime(frame)
            context.allowsImplicitAnimation = true
            super.transition(
                from: fromViewController, to: toViewController,
                options: [.crossfade, .allowUserInteraction], completionHandler: completion)
            if reduceMotion {
                window.setFrame(frame, display: true)
            } else {
                window.animator().setFrame(frame, display: false)
            }
        }
    }
}

struct SettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions
    // Lives here so the selection survives pane rebuilds.
    var appRuleSelection = AppRuleSelection()

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(model: model, actions: actions)
            case .tiling: TilingPane(model: model)
            case .appearance: AppearancePane(model: model)
            case .apps: AppsPane(model: model, selection: appRuleSelection)
            case .workspaces: WorkspacesPane(workspaces: model.workspaces)
            }
        }
        .formStyle(.grouped)
        // Not scrollDisabled, which also disables scrolling inside the pane.
        .scrollBounceBehavior(.basedOnSize)
        .modifier(PaneHeight(pane: pane))
        .frame(width: settingsPaneWidth)
    }
}

// Apps grows with every rule, so it caps its height and scrolls.
private struct PaneHeight: ViewModifier {
    let pane: SettingsPane

    func body(content: Content) -> some View {
        if pane == .apps {
            content.frame(maxHeight: 560)
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            ApplyFailureSection(model: model)
            Section {
                Toggle("Start BobrWM at login", isOn: $model.settings.startAtLogin)
            }

            Section {
                Toggle("Focus follows mouse", isOn: $model.settings.focusFollowsMouse)
                Toggle("Swipe to switch workspaces", isOn: $model.settings.swipeEnabled)
                Toggle("Reverse swipe direction", isOn: $model.settings.swipeReversed)
                    .disabled(!model.settings.swipeEnabled)
            } header: {
                Text("Mouse and Trackpad")
            } footer: {
                Text("Focus follows mouse focuses a window without raising it. Swiping uses the horizontal Spaces gesture.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        StatusLabel("Granted", succeeded: true)
                    } else {
                        Button("Open System Settings…") { actions.openAccessibilitySettings() }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                if !model.accessibilityGranted {
                    Text("BobrWM needs Accessibility access to move and resize windows.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Config file") {
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Toggle("Reload when the file changes", isOn: $model.settings.autoReloadConfig)
                LabeledContent("Last reload") {
                    StatusLabel(model.configStatus.message, succeeded: model.configStatus.succeeded)
                        .help(model.configStatus.date.formatted(date: .abbreviated, time: .standard))
                }
                HStack {
                    Spacer()
                    Button("Reveal in Finder") { actions.revealConfig(path: model.configPath) }
                        .disabled(model.configPath == nil)
                    Button("Open") { actions.openConfig() }
                    Button("Reload") { actions.reloadConfig() }
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("Changes made here are written to config.zon. Everything else in the file is left as is.")
                    .foregroundStyle(.secondary)
            }

            Section("Troubleshooting") {
                LabeledContent("Version", value: displayVersion)
                LabeledContent {
                    Button("Copy") { actions.copyDiagnostics(model.diagnostics) }
                } label: {
                    Text("Diagnostics")
                    Text("Version, permissions, and workspace state. No window titles or file contents.")
                }
            }
        }
    }

    private var displayPath: String {
        guard let path = model.configPath else { return "Built-in defaults" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var displayVersion: String {
        model.appVersion == "development" ? "Development build" : model.appVersion
    }
}

private struct TilingPane: View {
    @ObservedObject var model: SettingsModel

    private var settings: EditableSettings { model.settings }

    var body: some View {
        Form {
            ApplyFailureSection(model: model)
            Section {
                Picker("Layout", selection: $model.settings.layout) {
                    ForEach(LayoutSetting.allCases) { Text($0.title).tag($0) }
                }
                Group {
                    Picker("Split direction", selection: $model.settings.split) {
                        ForEach(SplitSetting.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Insert new windows at", selection: $model.settings.insertionPoint) {
                        ForEach(InsertionPointSetting.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Place new window", selection: $model.settings.newWindowPosition) {
                        ForEach(NewWindowPositionSetting.allCases) { Text($0.title).tag($0) }
                    }
                    PercentSlider("Split ratio", value: $model.settings.splitRatio, in: 0.1...0.9)
                }
                .disabled(settings.layout != .bsp)
            } footer: {
                Text(layoutFooter).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Follow app resizes", isOn: $model.settings.followAppResizes)
            } footer: {
                Text("When an app resizes its own window, for example to show a sidebar, the neighboring splits make room instead of the window snapping back.")
                    .foregroundStyle(.secondary)
            }

            Section {
                NumberStepper("Between windows", value: $model.settings.innerGap, in: 0...128, unit: "pt")
            } header: {
                Text("Gaps")
            }

            Section {
                NumberStepper("Top", value: $model.settings.outerGapTop, in: 0...128, unit: "pt")
                NumberStepper("Bottom", value: $model.settings.outerGapBottom, in: 0...128, unit: "pt")
                NumberStepper("Left", value: $model.settings.outerGapLeft, in: 0...128, unit: "pt")
                NumberStepper("Right", value: $model.settings.outerGapRight, in: 0...128, unit: "pt")
            } header: {
                Text("Screen Edges")
            }
        }
    }

    private var layoutFooter: String {
        guard settings.layout == .bsp else {
            return "Monocle shows one window at a time. Split options apply to the BSP layout."
        }
        return switch settings.insertionPoint {
        case .focused: "New windows split the focused window."
        case .first: "New windows split the first window in the layout."
        case .last: "New windows split the last window in the layout."
        case .minimumDepth: "New windows split the largest window, keeping the layout balanced."
        }
    }
}

private struct AppearancePane: View {
    @ObservedObject var model: SettingsModel

    private var settings: EditableSettings { model.settings }

    var body: some View {
        Form {
            ApplyFailureSection(model: model)
            Section {
                Toggle("Dim inactive windows", isOn: $model.settings.dimmingEnabled)
                // 0% dims nothing and 100% blacks windows out.
                PercentSlider("Dimming", value: $model.settings.dimmingLevel, in: 0.05...0.9)
                    .disabled(!settings.dimmingEnabled)
            }

            Section {
                Toggle("Animate window movement", isOn: $model.settings.animationEnabled)
                Group {
                    NumberStepper(
                        "Duration",
                        value: $model.settings.animationDurationMilliseconds,
                        in: 50...2_000,
                        step: 50,
                        unit: "ms"
                    )
                    Picker("Easing", selection: $model.settings.easing) {
                        ForEach(EasingSetting.allCases) { Text($0.title).tag($0) }
                    }
                }
                .disabled(!settings.animationEnabled)
            }
        }
    }
}

final class AppRuleSelection: ObservableObject {
    @Published var workspace: Set<String> = []
    @Published var floating: Set<String> = []
}

private struct AppsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: AppRuleSelection

    var body: some View {
        Form {
            ApplyFailureSection(model: model)
            Section {
                if !pinned.isEmpty {
                    Table(pinned, selection: $selection.workspace) {
                        TableColumn("App") { rule in
                            AppRuleLabel(appID: rule.appID)
                        }
                        TableColumn("Workspace") { rule in
                            Picker("Workspace", selection: workspaceBinding(rule.appID)) {
                                ForEach(model.workspaces) { Text($0.label).tag($0.id) }
                            }
                            .labelsHidden()
                            .buttonStyle(.borderless)
                        }
                        .width(140)
                    }
                    .onDeleteCommand { unpin(selection.workspace) }
                    .frame(height: fittedTableHeight(rows: pinned.count, header: true))
                }
                AddRemoveButtons(
                    excluded: Set(pinned.map(\.appID)),
                    canRemove: !selection.workspace.isEmpty,
                    add: { update($0) { $0.workspace = $0.workspace ?? 1 } },
                    remove: { unpin(selection.workspace) }
                )
            } header: {
                Text("Open on a Workspace")
            }

            Section {
                if !floating.isEmpty {
                    Table(floating, selection: $selection.floating) {
                        TableColumn("App") { rule in
                            AppRuleLabel(appID: rule.appID)
                        }
                    }
                    .tableColumnHeaders(.hidden)
                    .onDeleteCommand { unfloat(selection.floating) }
                    .frame(height: fittedTableHeight(rows: floating.count, header: false))
                }
                AddRemoveButtons(
                    excluded: Set(floating.map(\.appID)),
                    canRemove: !selection.floating.isEmpty,
                    add: { update($0) { $0.floats = true } },
                    remove: { unfloat(selection.floating) }
                )
            } header: {
                Text("Always Float")
            } footer: {
                Text("Rules apply to windows an app opens from now on.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pinned: [AppRule] { model.appRules.filter { $0.workspace != nil } }
    private var floating: [AppRule] { model.appRules.filter(\.floats) }

    private func workspaceBinding(_ appID: String) -> Binding<UInt8> {
        Binding(
            get: { model.appRules.first { $0.appID == appID }?.workspace ?? 1 },
            set: { workspace in update(appID) { $0.workspace = workspace } }
        )
    }

    private func update(_ appID: String, _ change: (inout AppRule) -> Void) {
        if let index = model.appRules.firstIndex(where: { $0.appID == appID }) {
            change(&model.appRules[index])
        } else {
            var rule = AppRule(appID: appID)
            change(&rule)
            model.appRules.append(rule)
        }
    }

    private func unpin(_ appIDs: Set<String>) {
        clear(appIDs) { $0.workspace = nil }
        selection.workspace.removeAll()
    }

    private func unfloat(_ appIDs: Set<String>) {
        clear(appIDs) { $0.floats = false }
        selection.floating.removeAll()
    }

    private func clear(_ appIDs: Set<String>, _ change: (inout AppRule) -> Void) {
        for index in model.appRules.indices where appIDs.contains(model.appRules[index].appID) {
            change(&model.appRules[index])
        }
        model.appRules.removeAll { $0.workspace == nil && !$0.floats }
    }
}

// A Table inside a Form gets no scroll events, so it is sized to show every
// row: AppKit's 28pt header and 24pt rows.
private func fittedTableHeight(rows: Int, header: Bool) -> CGFloat {
    (header ? 28 : 0) + CGFloat(rows) * 24
}

private struct AppRuleLabel: View {
    let appID: String

    var body: some View {
        let app = InstalledApp(bundleID: appID)
        Label {
            Text(app.name)
        } icon: {
            Image(nsImage: app.icon)
        }
    }
}

private struct AddRemoveButtons: View {
    let excluded: Set<String>
    let canRemove: Bool
    let add: (String) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(InstalledApp.running.filter { !excluded.contains($0.bundleID) }) { app in
                    Button {
                        add(app.bundleID)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
                Divider()
                Button("Other…") {
                    if let bundleID = InstalledApp.choose(), !excluded.contains(bundleID) {
                        add(bundleID)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an app")

            Button(action: remove) {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Remove the selected apps")

            Spacer()
        }
    }
}

struct InstalledApp: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage

    var id: String { bundleID }

    init(bundleID: String) {
        self.bundleID = bundleID
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icon.size = NSSize(width: 16, height: 16)
    }

    static var running: [InstalledApp] {
        let own = Bundle.main.bundleIdentifier
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.activationPolicy == .regular ? app.bundleIdentifier : nil
        })
        return ids.filter { $0 != own }
            .map(InstalledApp.init(bundleID:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

private struct WorkspacesPane: View {
    let workspaces: [WorkspaceInfo]

    var body: some View {
        Form {
            Section {
                ForEach(workspaces) { workspace in
                    WorkspaceSettingsRow(workspace: workspace)
                }
            } footer: {
                Text("Names and shortcuts are defined in config.zon.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkspaceSettingsRow: View {
    let workspace: WorkspaceInfo

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                if workspace.isFocused {
                    Text("Focused")
                } else if workspace.isActive {
                    Text("Visible")
                }
                Text("^[\(workspace.windowCount) window](inflect: true)").monospacedDigit()
            }
            .foregroundStyle(.secondary)
        } label: {
            HStack(spacing: 6) {
                Text(workspace.label)
                if let shortcut = workspace.shortcut {
                    ShortcutView(shortcut: shortcut).foregroundStyle(.tertiary)
                }
            }
            Text(workspace.applicationNames.isEmpty
                ? "No apps"
                : workspace.applicationNames.joined(separator: ", "))
        }
    }
}

// The symbol keeps success and failure distinguishable without color.
private struct StatusLabel: View {
    let title: String
    let succeeded: Bool

    init(_ title: String, succeeded: Bool) {
        self.title = title
        self.succeeded = succeeded
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(succeeded ? Color.green : Color.orange)
        }
    }
}

private struct ApplyFailureSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if model.applyFailed {
            Section {
                LabeledContent {
                    Button("Revert") { model.revertSettings() }
                } label: {
                    Label {
                        Text("Changes weren't applied")
                        Text(model.configStatus.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        LabeledContent(title) {
            // Rounded through the binding: `step:` draws a tick per step.
            Slider(value: rounded, in: range)
                .labelsHidden()
            // Reserves the widest value so the slider doesn't shift while dragging.
            Text(range.upperBound, format: .percent.precision(.fractionLength(0)))
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(value, format: .percent.precision(.fractionLength(0)))
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var rounded: Binding<Double> {
        Binding(
            get: { value },
            set: { value = ($0 * 100).rounded() / 100 }
        )
    }
}

private struct NumberStepper<Value: BinaryInteger>: View {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value
    let unit: String

    init(
        _ title: String,
        value: Binding<Value>,
        in range: ClosedRange<Value>,
        step: Value = 1,
        unit: String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        Stepper(
            value: clamped,
            in: Double(range.lowerBound)...Double(range.upperBound),
            step: Double(step),
            format: .number.precision(.fractionLength(0))
        ) {
            Text("\(title) (\(unit))")
        }
    }

    // The stepper's text field needs a Double. Clamped, since the core rejects
    // the whole write for one out-of-range value.
    private var clamped: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: {
                let bounded = min(max($0.rounded(), Double(range.lowerBound)), Double(range.upperBound))
                value = Value(bounded)
            }
        )
    }
}
