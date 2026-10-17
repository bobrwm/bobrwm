import AppKit
import ApplicationServices
import BobrwmUIABI
import Combine
import SwiftUI

struct WorkspaceInfo: Identifiable {
    let id: UInt8
    let name: String
    let shortcut: String?
    var applicationNames: [String] = []
    var windowCount: UInt32 = 0
    var isActive = false
    var isFocused = false

    var label: String {
        name.isEmpty || name == "\(id)" ? "Workspace \(id)" : name
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
            start_at_login: startAtLogin
        )
    }
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
    @Published private(set) var configStatus = ConfigStatus(
        succeeded: true,
        message: "Configuration loaded",
        date: Date()
    )

    let configPath: String?

    init(configPath: String?) {
        self.configPath = configPath
        accessibilityGranted = AXIsProcessTrusted()
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

    /// True when the last apply was rejected and the shown values no longer
    /// match what is running.
    var applyFailed: Bool {
        !configStatus.succeeded && settings != appliedSettings
    }

    func revertSettings() {
        settings = appliedSettings
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    var diagnostics: String {
        let workspaceSummary = workspaces.map {
            "\($0.id):windows=\($0.windowCount):active=\($0.isActive):focused=\($0.isFocused)"
        }.joined(separator: "\n")
        return """
        Bobrwm \(appVersion)
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
    private let focusWorkspaceAction: (UInt8) -> Void

    init(callbacks: BWMenuBarCallbacks) {
        openConfigAction = { callbacks.open_config() }
        reloadConfigAction = { _ = callbacks.reload_config() }
        saveSettingsAction = { settings in
            var raw = settings.abiValue
            return withUnsafePointer(to: &raw) { callbacks.set_settings($0) }
        }
        focusWorkspaceAction = { callbacks.switch_to_workspace($0) }
    }

    private init(
        openConfig: @escaping () -> Void,
        reloadConfig: @escaping () -> Void,
        saveSettings: @escaping (EditableSettings) -> Bool,
        focusWorkspace: @escaping (UInt8) -> Void
    ) {
        openConfigAction = openConfig
        reloadConfigAction = reloadConfig
        saveSettingsAction = saveSettings
        focusWorkspaceAction = focusWorkspace
    }

    static let preview = SettingsActions(
        openConfig: {},
        reloadConfig: {},
        saveSettings: { _ in true },
        focusWorkspace: { _ in }
    )

    func openConfig() { openConfigAction() }
    func reloadConfig() { reloadConfigAction() }
    func saveSettings(_ settings: EditableSettings) -> Bool { saveSettingsAction(settings) }
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
    case workspaces

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .tiling: "Tiling"
        case .appearance: "Appearance"
        case .workspaces: "Workspaces"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .tiling: "rectangle.split.2x2"
        case .appearance: "paintbrush"
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

    init(model: SettingsModel, actions: SettingsActions) {
        self.model = model
        tabs = SettingsTabViewController(model: model, actions: actions)

        // Settings open quickly with ⌘, and size themselves to the pane, so
        // the HIG asks for minimize and zoom to stay disabled.
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        // Debounced so dragging a slider or holding a stepper rewrites
        // config.zon once the value settles rather than on every step.
        applySubscription = model.$settings
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak model] settings in
                guard let model, settings != model.appliedSettings else { return }
                _ = actions.saveSettings(settings)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not archivable")
    }

    func show(pane: SettingsPane? = nil) {
        model.refreshAccessibility()
        if let pane { tabs.select(pane) }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshAccessibility()
    }
}

/// Toolbar-style tabs give the standard settings chrome: a fixed toolbar that
/// always shows the selected pane and a window title that follows it.
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

        // People tend to adjust related settings repeatedly, so reopen on the
        // pane they used last.
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
        fitWindow(to: tabViewItem?.viewController, animate: view.window?.isVisible == true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard selectedTabViewItemIndex >= 0,
            tabViewItems[selectedTabViewItemIndex].viewController === viewController
        else { return }
        fitWindow(to: viewController, animate: view.window?.isVisible == true)
    }

    /// Resizes around the top edge so the toolbar stays put while the pane
    /// below it grows or shrinks.
    private func fitWindow(to viewController: NSViewController?, animate: Bool) {
        guard let window = view.window, let viewController else { return }
        let size = viewController.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }

        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: animate)
    }
}

struct SettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(model: model, actions: actions)
            case .tiling: TilingPane(model: model)
            case .appearance: AppearancePane(model: model)
            case .workspaces: WorkspacesPane(workspaces: model.workspaces)
            }
        }
        .formStyle(.grouped)
        // The pane reports its full height so the window can fit it; scrolling
        // inside a window that already fits would only add a stray scroller.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: settingsPaneWidth)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            ApplyFailureSection(model: model)
            Section {
                Toggle("Start Bobrwm at login", isOn: $model.settings.startAtLogin)
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
                    Text("Bobrwm needs Accessibility access to move and resize windows.")
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
                NumberStepper("Between windows", value: $model.settings.innerGap, in: 0...128, unit: "px")
            } header: {
                Text("Gaps")
            }

            Section {
                NumberStepper("Top", value: $model.settings.outerGapTop, in: 0...128, unit: "px")
                NumberStepper("Bottom", value: $model.settings.outerGapBottom, in: 0...128, unit: "px")
                NumberStepper("Left", value: $model.settings.outerGapLeft, in: 0...128, unit: "px")
                NumberStepper("Right", value: $model.settings.outerGapRight, in: 0...128, unit: "px")
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
                // The extremes do nothing useful: 0% dims nothing and 100%
                // blacks windows out entirely.
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
                Text(windowSummary).monospacedDigit()
            }
            .foregroundStyle(.secondary)
        } label: {
            HStack(spacing: 6) {
                Text(workspace.label)
                if let shortcut = workspace.shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            Text(workspace.applicationNames.isEmpty
                ? "No apps"
                : workspace.applicationNames.joined(separator: ", "))
        }
    }

    private var windowSummary: String {
        switch workspace.windowCount {
        case 0: "—"
        case 1: "1 window"
        default: "\(workspace.windowCount) windows"
        }
    }
}

/// Pairs the status color with a symbol so success and failure stay
/// distinguishable without relying on color alone.
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
            HStack(spacing: 8) {
                // Rounded through the binding rather than with `step:`, which
                // draws a tick for every step and crowds the track.
                Slider(value: rounded, in: range)
                    .labelsHidden()
                    .frame(width: 160)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private var rounded: Binding<Double> {
        Binding(
            get: { value },
            set: { value = ($0 * 100).rounded() / 100 }
        )
    }
}

/// A typed field next to a stepper, the standard macOS pairing: arrows for
/// small nudges, typing for anything further than a few steps away.
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
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: clamped, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 56)
                Text(unit).foregroundStyle(.secondary)
                Stepper(
                    title,
                    value: clamped,
                    in: Int(range.lowerBound)...Int(range.upperBound),
                    step: Int(step)
                )
                    .labelsHidden()
            }
        }
    }

    /// Typed values outside the range snap to the nearest bound instead of
    /// reaching the core, which would reject the whole settings write.
    private var clamped: Binding<Int> {
        Binding(
            get: { Int(value) },
            set: { value = Value(min(max($0, Int(range.lowerBound)), Int(range.upperBound))) }
        )
    }
}
