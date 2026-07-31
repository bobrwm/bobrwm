import AppKit
import SwiftUI

/// Per-row observable state.
///
/// Highlight is driven by `NSMenuDelegate.menu(_:willHighlight:)`: custom menu
/// item views suppress AppKit's own highlight drawing, so the row has to
/// render it, and the delegate callback keeps keyboard navigation working
/// where mouse tracking alone would miss it.
///
/// Focus lives here rather than in the row's stored properties so the active
/// workspace can change without rebuilding the menu, which matters because
/// focus moves while the menu is open.
final class RowState: ObservableObject {
    @Published var isHighlighted = false
    @Published var isFocused = false
}

/// Shared chrome for every row: menu metrics, highlight fill, and the text
/// color inversion AppKit would otherwise apply for us.
struct MenuRow<Content: View>: View {
    @ObservedObject var state: RowState
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(state.isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 20, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(state.isHighlighted ? Color.accentColor : Color.clear)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
    }
}

struct ActionRow: View {
    @ObservedObject var state: RowState
    let title: String

    var body: some View {
        MenuRow(state: state) {
            HStack(spacing: 0) {
                Text(title)
                Spacer(minLength: 24)
            }
        }
    }
}

struct WorkspaceRow: View {
    @ObservedObject var state: RowState
    let id: UInt8
    let name: String
    let windowCount: UInt32

    var body: some View {
        MenuRow(state: state) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .opacity(state.isFocused ? 1 : 0)

                Text("\(id)")
                    .monospacedDigit()
                    .foregroundStyle(secondaryStyle)

                if !name.isEmpty {
                    Text(name)
                }

                Spacer(minLength: 24)

                Text(windowCount == 1 ? "1 window" : "\(windowCount) windows")
                    .foregroundStyle(secondaryStyle)
            }
        }
    }

    private var secondaryStyle: AnyShapeStyle {
        state.isHighlighted ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary)
    }
}

/// Menu item that owns its SwiftUI row and the state feeding it.
/// Named `rowState` because `NSMenuItem.state` is the on/off/mixed checkmark.
final class RowItem: NSMenuItem {
    let rowState = RowState()
}

/// Hosts a row's SwiftUI content inside a menu item.
///
/// NSMenuItem does not fire its action for items with a custom view, so the
/// click has to be turned back into the normal target/action path by hand.
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

        // NSMenu stretches item views to the menu width but takes the initial
        // width from the fitting size, so the widest row sets the menu width.
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

        // Dismiss first: performActionForItem runs the handler synchronously
        // and workspace switches expect the menu to be gone already.
        menu.cancelTracking()
        menu.performActionForItem(at: index)
    }
}
