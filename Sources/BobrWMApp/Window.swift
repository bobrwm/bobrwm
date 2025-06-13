import Foundation

struct Window: Identifiable, Hashable {
    let id: UInt32
    var frame: CGRect
    var workspace: Int
    
    init(id: UInt32, frame: CGRect = .zero, workspace: Int = 0) {
        self.id = id
        self.frame = frame
        self.workspace = workspace
    }
}