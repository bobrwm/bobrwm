import Foundation

actor WindowManager {
    private var windows: [UInt32: Window] = [:]
    private var workspaceWindows: [Int: Set<UInt32>] = [:]
    
    func addWindow(_ window: Window) {
        windows[window.id] = window
        workspaceWindows[window.workspace, default: []].insert(window.id)
    }
    
    func removeWindow(id: UInt32) -> Window? {
        guard let window = windows.removeValue(forKey: id) else { return nil }
        workspaceWindows[window.workspace]?.remove(id)
        return window
    }
    
}
