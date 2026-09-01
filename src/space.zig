//! Stable Space identity and placement.

const std = @import("std");

pub const WorkspaceId = u8;
pub const DisplayId = u32;
pub const NativeSpaceId = u64;

pub const Key = union(enum) {
    virtual: WorkspaceId,
    native: NativeSpaceId,

    pub fn eql(left: Key, right: Key) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .virtual => |value| value == right.virtual,
            .native => |value| value == right.native,
        };
    }
};

pub const Ref = struct {
    key: Key,
    workspace_id: WorkspaceId,
    display_id: DisplayId,

    pub fn assertValid(self: Ref) void {
        std.debug.assert(self.workspace_id != 0);
        std.debug.assert(self.display_id != 0);
        switch (self.key) {
            .virtual => |workspace_id| std.debug.assert(workspace_id == self.workspace_id),
            .native => |space_id| std.debug.assert(space_id != 0),
        }
    }
};

test "native keys do not collide across displays" {
    const left: Key = .{ .native = 101 };
    const right: Key = .{ .native = 201 };

    try std.testing.expect(!left.eql(right));
}
