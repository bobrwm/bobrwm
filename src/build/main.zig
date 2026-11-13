//! Build logic for bobrwm, split out of build.zig the way Ghostty does it.
//! build.zig wires these together into steps.

pub const AppVersion = @import("AppVersion.zig");
pub const Config = @import("Config.zig");
pub const GitVersion = @import("GitVersion.zig");
pub const HelpStrings = @import("HelpStrings.zig");
pub const SharedDeps = @import("SharedDeps.zig");

// Artifacts
pub const BobrwmApp = @import("BobrwmApp.zig");
pub const BobrwmBundle = @import("BobrwmBundle.zig");
pub const BobrwmCli = @import("BobrwmCli.zig");
pub const BobrwmCore = @import("BobrwmCore.zig");
pub const BobrwmUiPreview = @import("BobrwmUiPreview.zig");
pub const BobrwmWebdata = @import("BobrwmWebdata.zig");
