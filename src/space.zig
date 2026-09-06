//! Stable Space identity and placement.

const std = @import("std");

pub const WorkspaceId = u8;
pub const DisplayId = u32;
pub const NativeSpaceId = u64;

pub const Key = struct {
    id: NativeSpaceId,

    pub fn eql(left: Key, right: Key) bool {
        return left.id == right.id;
    }
};

pub const Ref = struct {
    key: Key,
    workspace_id: WorkspaceId,
    display_id: DisplayId,

    pub fn assertValid(self: Ref) void {
        std.debug.assert(self.workspace_id != 0);
        std.debug.assert(self.display_id != 0);
        std.debug.assert(self.key.id != 0);
    }
};

test "physical keys do not collide across displays" {
    const left: Key = .{ .id = 101 };
    const right: Key = .{ .id = 201 };

    try std.testing.expect(!left.eql(right));
}
