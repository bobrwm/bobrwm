import AppKit
import ApplicationServices
import BobrwmUIABI
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

struct EditableSettings {
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

    func setSettings(_ settings: BWSettings) {
        self.settings = EditableSettings(settings)
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
    private let retileAction: () -> Void
    private let openConfigAction: () -> Void
    private let reloadConfigAction: () -> Void
    private let saveSettingsAction: (EditableSettings) -> Bool
    private let focusWorkspaceAction: (UInt8) -> Void

    init(callbacks: BWMenuBarCallbacks) {
        retileAction = { callbacks.retile() }
        openConfigAction = { callbacks.open_config() }
        reloadConfigAction = { _ = callbacks.reload_config() }
        saveSettingsAction = { settings in
            var raw = settings.abiValue
            return withUnsafePointer(to: &raw) { callbacks.set_settings($0) }
        }
        focusWorkspaceAction = { callbacks.switch_to_workspace($0) }
    }

    private init(
        retile: @escaping () -> Void,
        openConfig: @escaping () -> Void,
        reloadConfig: @escaping () -> Void,
        saveSettings: @escaping (EditableSettings) -> Bool,
        focusWorkspace: @escaping (UInt8) -> Void
    ) {
        retileAction = retile
        openConfigAction = openConfig
        reloadConfigAction = reloadConfig
        saveSettingsAction = saveSettings
        focusWorkspaceAction = focusWorkspace
    }

    static let preview = SettingsActions(
        retile: {},
        openConfig: {},
        reloadConfig: {},
        saveSettings: { _ in true },
        focusWorkspace: { _ in }
    )

    func retile() { retileAction() }
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

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel

    init(model: SettingsModel, actions: SettingsActions) {
        self.model = model
        let rootView = SettingsView(
            model: model,
            actions: actions,
            initialSection: .general
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 560))
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not archivable")
    }

    func show() {
        model.refreshAccessibility()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshAccessibility()
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case workspaces
    case configuration
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .workspaces: "Workspaces"
        case .configuration: "Configuration"
        case .diagnostics: "Diagnostics"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions
    @State private var selectedSection: SettingsSection

    init(
        model: SettingsModel,
        actions: SettingsActions,
        initialSection: SettingsSection
    ) {
        self.model = model
        self.actions = actions
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    Button { selectedSection = section } label: {
                        Text(section.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(
                                selectedSection == section
                                    ? Color.white : Color(nsColor: .labelColor)
                            )
                            .background(
                                selectedSection == section ? Color.accentColor : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .navigationSplitViewColumnWidth(min: 165, ideal: 175, max: 190)
        } detail: {
            sectionContent
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .general:
            sectionPage(
                title: "General",
                subtitle: "Status, permissions, and quick actions."
            ) {
                generalContent
            }
        case .workspaces:
            sectionPage(
                title: "Workspaces",
                subtitle: "Live workspace status from your running Bobrwm session.",
                trailing: "\(model.workspaces.count) total"
            ) {
                workspacesContent
            }
        case .configuration:
            sectionPage(
                title: "Configuration",
                subtitle: "Window management and application behavior."
            ) {
                configurationContent
            }
        case .diagnostics:
            sectionPage(
                title: "Diagnostics",
                subtitle: "Runtime information for troubleshooting."
            ) {
                diagnosticsContent
            }
        }
    }

    private func sectionPage<Content: View>(
        title: String,
        subtitle: String,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 24, weight: .semibold))
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing).foregroundStyle(.secondary)
                    }
                }
                content()
                sourceOfTruthNote
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generalContent: some View {
        VStack(spacing: 10) {
            StatusCard(
                title: "Bobrwm is running",
                detail: "Managing windows with your config.zon",
                color: .green
            ) {
                Button("Retile") { actions.retile() }
            }

            StatusCard(
                title: "Accessibility",
                detail: model.accessibilityGranted
                    ? "Granted · Bobrwm can control your windows"
                    : "Required · Grant access to control your windows",
                color: model.accessibilityGranted ? .green : .orange
            ) {
                Button("Open Settings…") { actions.openAccessibilitySettings() }
            }

            DashboardCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Version").fontWeight(.semibold)
                        Text("Keyboard-driven tiling window manager")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(displayVersion).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var workspacesContent: some View {
        DashboardCard {
            HStack {
                Text("Key").frame(width: 34, alignment: .leading)
                Text("Workspace").frame(width: 92, alignment: .leading)
                Text("Apps").frame(maxWidth: .infinity, alignment: .leading)
                Text("Windows").frame(width: 58, alignment: .leading)
                Text("Status").frame(width: 72, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(model.workspaces) { workspace in
                Divider()
                Button { actions.focusWorkspace(workspace.id) } label: {
                    HStack {
                        Text(workspace.shortcut.map(shortcutKeyLabel) ?? "\(workspace.id)")
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .frame(width: 34, alignment: .leading)
                        Text(workspace.label)
                            .fontWeight(workspace.isFocused ? .semibold : .regular)
                            .frame(width: 92, alignment: .leading)
                        Text(applicationSummary(workspace.applicationNames))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(applicationSummary(workspace.applicationNames))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(workspace.windowCount)")
                            .frame(width: 58, alignment: .leading)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(workspace.isActive ? Color.accentColor : .secondary)
                                .frame(width: 7, height: 7)
                            Text(workspace.isActive ? "active" : "inactive")
                        }
                        .frame(width: 72, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var configurationContent: some View {
        VStack(spacing: 10) {
            DashboardCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Editable settings").fontWeight(.semibold)
                        Text("Changes are validated, saved to config.zon, and applied immediately.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Settings") { _ = actions.saveSettings(model.settings) }
                        .keyboardShortcut("s", modifiers: .command)
                }
            }

            DashboardCard {
                settingHeader("Layout")
                settingRow("Algorithm") {
                    Picker("Algorithm", selection: $model.settings.layout) {
                        ForEach(LayoutSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                Divider()
                settingRow("Split direction") {
                    Picker("Split direction", selection: $model.settings.split) {
                        ForEach(SplitSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                .disabled(model.settings.layout != .bsp)
                settingRow("Insertion point") {
                    Picker("Insertion point", selection: $model.settings.insertionPoint) {
                        ForEach(InsertionPointSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                .disabled(model.settings.layout != .bsp)
                settingRow("New window position") {
                    Picker("New window position", selection: $model.settings.newWindowPosition) {
                        ForEach(NewWindowPositionSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                .disabled(model.settings.layout != .bsp)
                settingRow("Default split ratio") {
                    HStack(spacing: 10) {
                        Slider(value: $model.settings.splitRatio, in: 0.1...0.9, step: 0.05)
                            .frame(width: 120)
                        Text(model.settings.splitRatio, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(model.settings.layout != .bsp)
            }

            DashboardCard {
                settingHeader("Gaps")
                gapStepper("Inner", value: $model.settings.innerGap)
                Divider()
                gapStepper("Left", value: $model.settings.outerGapLeft)
                gapStepper("Right", value: $model.settings.outerGapRight)
                gapStepper("Top", value: $model.settings.outerGapTop)
                gapStepper("Bottom", value: $model.settings.outerGapBottom)
            }

            DashboardCard {
                settingHeader("Appearance")
                Toggle("Dim inactive windows", isOn: $model.settings.dimmingEnabled)
                settingRow("Dimming level") {
                    HStack(spacing: 10) {
                        Slider(value: $model.settings.dimmingLevel, in: 0...1, step: 0.05)
                            .frame(width: 120)
                        Text(model.settings.dimmingLevel, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!model.settings.dimmingEnabled)
                Divider()
                Toggle("Animate window movement", isOn: $model.settings.animationEnabled)
                settingRow("Duration") {
                    Stepper(
                        "\(model.settings.animationDurationMilliseconds) ms",
                        value: $model.settings.animationDurationMilliseconds,
                        in: 50...2_000,
                        step: 50
                    )
                    .monospacedDigit()
                }
                .disabled(!model.settings.animationEnabled)
                settingRow("Easing") {
                    Picker("Easing", selection: $model.settings.easing) {
                        ForEach(EasingSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                .disabled(!model.settings.animationEnabled)
            }

            DashboardCard {
                settingHeader("Application")
                Toggle("Start Bobrwm at login", isOn: $model.settings.startAtLogin)
            }

            DashboardCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Config file").fontWeight(.medium)
                        Text(displayPath)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Divider()
                HStack {
                    Button("Open") { actions.openConfig() }
                    Button("Reveal in Finder") {
                        actions.revealConfig(path: model.configPath)
                    }
                    .disabled(model.configPath == nil)
                    Button("Reload Config") {
                        actions.reloadConfig()
                    }
                }
            }

            DashboardCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last reload").fontWeight(.medium)
                        Text(model.configStatus.date, style: .time)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(model.configStatus.succeeded ? Color.green : .orange)
                        .frame(width: 8, height: 8)
                    Text(model.configStatus.message)
                }
            }
        }
    }

    private var diagnosticsContent: some View {
        VStack(spacing: 10) {
            DashboardCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Diagnostics snapshot").fontWeight(.semibold)
                        Text("Captures version, permission status, workspace list, and runtime state. Does not include window titles, file paths, or personal content.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Copy Diagnostics") { actions.copyDiagnostics(model.diagnostics) }
                }
            }

            DashboardCard {
                diagnosticRow(
                    title: "Version",
                    status: displayVersion,
                    detail: "Keyboard-driven tiling window manager",
                    color: nil
                )
                Divider()
                diagnosticRow(
                    title: "Accessibility",
                    status: model.accessibilityGranted ? "Granted" : "Required",
                    detail: model.accessibilityGranted
                        ? "Bobrwm can control your windows"
                        : "Grant access in System Settings",
                    color: model.accessibilityGranted ? .green : .orange
                )
            }
        }
    }

    private func diagnosticRow(
        title: String,
        status: String,
        detail: String,
        color: Color?
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let color {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(status).foregroundStyle(.secondary)
        }
    }

    private var sourceOfTruthNote: some View {
        Text("config.zon remains the source of truth. Settings changed here are written through the Zig core without rewriting unrelated configuration.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func settingHeader(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    private func gapStepper(_ title: String, value: Binding<UInt16>) -> some View {
        settingRow(title) {
            Stepper("\(value.wrappedValue) px", value: value, in: 0...128)
                .monospacedDigit()
        }
    }

    private var displayPath: String {
        guard let path = model.configPath else { return "Built-in defaults" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var displayVersion: String {
        model.appVersion == "development" ? "Development" : model.appVersion
    }

    private func applicationSummary(_ names: [String]) -> String {
        names.isEmpty ? "—" : names.joined(separator: ", ")
    }
}

private struct StatusCard<Actions: View>: View {
    let title: String
    let detail: String
    let color: Color
    @ViewBuilder let actions: Actions

    var body: some View {
        DashboardCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(title).fontWeight(.semibold)
                    }
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actions
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}
