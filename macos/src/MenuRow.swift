import AppKit
import SwiftUI

final class RowState: ObservableObject {
    @Published var isHighlighted = false
    @Published var isActive = false
    @Published var isFocused = false
    @Published var windowCount: UInt32 = 0
}

enum Metrics {
    /// Inset of the highlight rect from the menu edge, matching AppKit.
    static let highlightInset: CGFloat = 5
    /// Text inset inside the highlight rect. Sums with `highlightInset` to the
    /// ~17pt leading edge macOS uses for menu item titles.
    static let textInset: CGFloat = 12
    static let rowHeight: CGFloat = 20
    /// Leading column for the focused/visible mark, matching the gutter AppKit
    /// reserves for an item's state image.
    static let stateWidth: CGFloat = 18
    /// Wide enough for a two-digit count; narrower truncates "12" to an ellipsis.
    static let countWidth: CGFloat = 20
    static let shortcutWidth: CGFloat = 30
}

func shortcutKeyLabel(_ shortcut: String) -> String {
    String(shortcut.drop(while: { "⌃⌥⇧⌘".contains($0) }))
}

private struct MenuRow<Content: View>: View {
    @ObservedObject var state: RowState
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(state.isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, Metrics.textInset)
            .frame(height: Metrics.rowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(state.isHighlighted ? Color.accentColor : Color.clear)
            }
            .padding(.horizontal, Metrics.highlightInset)
            .padding(.vertical, 1)
    }
}

private struct ShortcutHint: View {
    @ObservedObject var state: RowState
    let shortcut: String?

    var body: some View {
        Text(shortcut ?? "")
            .font(.system(size: 12))
            .foregroundStyle(
                state.isHighlighted ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary)
            )
            .frame(width: Metrics.shortcutWidth, alignment: .trailing)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, Metrics.stateWidth)
            .padding(.horizontal, Metrics.highlightInset + Metrics.textInset)
            .frame(height: 16, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
            .padding(.bottom, 1)
    }
}

struct ActionRow: View {
    @ObservedObject var state: RowState
    let title: String
    var shortcut: String?

    var body: some View {
        MenuRow(state: state) {
            HStack(spacing: 0) {
                // Shares the state gutter with workspace rows so every title
                // starts on the same edge, as in an AppKit menu.
                Text(title).padding(.leading, Metrics.stateWidth)
                Spacer(minLength: 20)
                ShortcutHint(state: state, shortcut: shortcut)
            }
        }
    }
}

struct WorkspaceRow: View {
    @ObservedObject var state: RowState
    let id: UInt8
    let name: String
    var shortcut: String?

    var body: some View {
        MenuRow(state: state) {
            HStack(spacing: 0) {
                WorkspaceStateMark(state: state)

                Text(name.isEmpty || name == "\(id)" ? "Workspace \(id)" : name)

                Spacer(minLength: 20)

                Text(state.windowCount == 0 ? "—" : "\(state.windowCount)")
                    .monospacedDigit()
                    .foregroundStyle(
                        state.isHighlighted
                            ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary)
                    )
                    .frame(width: Metrics.countWidth, alignment: .trailing)
                    .padding(.trailing, 9)

                ShortcutHint(state: state, shortcut: shortcut)
            }
        }
    }
}

/// Uses AppKit's menu state vocabulary instead of a bespoke badge: a checkmark
/// marks the focused workspace and a dot marks one visible on another display,
/// the same way NSMenuItem shows on and mixed states.
private struct WorkspaceStateMark: View {
    @ObservedObject var state: RowState

    var body: some View {
        // The clear base keeps the gutter's width when there is no mark; an
        // empty conditional would collapse and shift the title left.
        ZStack(alignment: .leading) {
            Color.clear.frame(width: Metrics.stateWidth, height: 1)
            if state.isFocused {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            } else if state.isActive {
                Circle()
                    .frame(width: 5, height: 5)
                    .padding(.leading, 3)
            }
        }
    }
}

final class StatusModel: ObservableObject {
    struct Chip: Identifiable {
        let id: UInt8
        let label: String
        let name: String
        let isFocused: Bool
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
    }
}

private struct StatusChip: View {
    let chip: StatusModel.Chip

    var body: some View {
        HStack(spacing: 4) {
            Text(chip.label)
                .monospacedDigit()
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

final class RowItem: NSMenuItem {
    let rowState = RowState()
}

final class MenuRowHostView<Content: View>: NSView {
    private let hosting: NSHostingView<Content>

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        frame = NSRect(origin: .zero, size: hosting.fittingSize)
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MenuRowHostView is not archivable")
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }

        let index = menu.index(of: item)
        guard index >= 0 else { return }

        menu.cancelTracking()
        menu.performActionForItem(at: index)
    }
}

final class StatusBarHostingView: NSHostingView<StatusBarView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
