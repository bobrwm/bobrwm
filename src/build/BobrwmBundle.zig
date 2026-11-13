//! Bobrwm.app. An .app is only a directory tree with an Info.plist, so the
//! build system assembles it directly and no Xcode project is involved.
const BobrwmBundle = @This();

const std = @import("std");
const BobrwmApp = @import("BobrwmApp.zig");
const BobrwmCli = @import("BobrwmCli.zig");
const Config = @import("Config.zig");

pub const bundle_name = "Bobrwm.app";
pub const bundle_macos = bundle_name ++ "/Contents/MacOS";

// The window manager and the client ship side by side in Contents/MacOS, so
// their names have to differ by more than case: APFS is case-insensitive by
// default and `Bobrwm` would collide with `bobrwm`. The Homebrew cask
// symlinks the client into PATH as plain `bobrwm`.
pub const server_exe_name = "Bobrwm";
pub const cli_exe_name = "bobrwm-cli";

// launchd requires Label to match the plist's basename. src/loginitem.zig
// registers this same name through SMAppService.
const launchd_label = "com.bobrwm.bobrwm";

/// Signs the installed bundle when a codesign identity is set; the default
/// step then builds, installs, and signs.
sign_step: ?*std.Build.Step,

/// Installs the bundle as part of the install step.
pub fn init(b: *std.Build, config: *const Config, app: BobrwmApp, cli: BobrwmCli) BobrwmBundle {
    installFile(b, app.exe, "Contents/MacOS", server_exe_name);
    b.getInstallStep().dependOn(&b.addInstallArtifact(cli.exe, .{
        .dest_dir = .{ .override = .{ .custom = bundle_macos } },
    }).step);

    installFile(b, infoPlist(b, config.version), "Contents", "Info.plist");
    // Classic-era type/creator record. LaunchServices no longer needs it, but
    // some tooling still probes for it and it costs eight bytes.
    installFile(b, b.addWriteFiles().add("PkgInfo", "APPL????"), "Contents", "PkgInfo");
    installFile(b, launchAgentPlist(b), "Contents/Library/LaunchAgents", launchd_label ++ ".plist");

    return .{ .sign_step = if (config.codesign_identity) |identity| sign(b, identity) else null };
}

/// The installed copy of a file inside the bundle.
pub fn installedPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    const install_prefix: std.Build.LazyPath = .{
        .relative = .{ .base = .install_prefix },
    };
    return install_prefix.path(b, sub_path);
}

fn sign(b: *std.Build, identity: []const u8) *std.Build.Step {
    const step = b.step("codesign", "Code-sign the app bundle");

    // The app takes its identifier from CFBundleIdentifier.
    const sign_app = codesign(b, identity);
    sign_app.addFileArg(installedPath(b, bundle_name));

    // Nested code must be sealed before the enclosing bundle, otherwise the
    // outer signature covers a helper that is about to change.
    for ([_][3][]const u8{
        .{ bundle_macos, cli_exe_name, "com.bobrwm.cli" },
    }) |entry| {
        const sign_helper = codesign(b, identity);
        sign_helper.addArgs(&.{ "--identifier", entry[2] });
        sign_helper.addFileArg(installedPath(b, b.fmt("{s}/{s}", .{ entry[0], entry[1] })));
        sign_helper.step.dependOn(b.getInstallStep());
        sign_app.step.dependOn(&sign_helper.step);
    }

    step.dependOn(&sign_app.step);
    b.default_step = step;
    return step;
}

fn codesign(b: *std.Build, identity: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "codesign",
        "--force",
        "--sign",
        identity,
        // A self-signed identity has no timestamp authority, and the hardened
        // runtime blocks lldb without get-task-allow. Both are release-only
        // concerns.
        "--timestamp=none",
    });
    // The argument list never changes, but its input does.
    run.has_side_effects = true;
    return run;
}

fn installFile(b: *std.Build, source: std.Build.LazyPath, sub_dir: []const u8, dest_name: []const u8) void {
    const dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/{s}", .{ bundle_name, sub_dir }) };
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(source, dir, dest_name).step);
}

fn infoPlist(b: *std.Build, version: std.SemanticVersion) std.Build.LazyPath {
    // Both version keys must be dotted integers. The pre-release and build
    // metadata that AppVersion carries for `--version` would make
    // LaunchServices reject them, so they get the numeric triple only.
    const short_version = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });

    return b.addWriteFiles().add("Info.plist", b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{[server]s}</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>com.bobrwm.bobrwm</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>BobrWM</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>BobrWM</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{[version]s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>{[version]s}</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>15.0</string>
        \\    <key>LSUIElement</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ .server = server_exe_name, .version = short_version }));
}

/// LaunchAgent registered via SMAppService, which is what keeps launchd
/// supervising the process so a crash gets restarted.
fn launchAgentPlist(b: *std.Build) std.Build.LazyPath {
    return b.addWriteFiles().add(launchd_label ++ ".plist", std.fmt.comptimePrint(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{[label]s}</string>
        \\    <!-- Bundle-relative, so registration survives the app moving.
        \\         Only honoured for plists installed via SMAppService. -->
        \\    <key>BundleProgram</key>
        \\    <string>Contents/MacOS/{[server]s}</string>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <!-- Come back from a crash, but stay down after the user quits
        \\         from the menu bar. -->
        \\    <key>KeepAlive</key>
        \\    <dict>
        \\        <key>SuccessfulExit</key>
        \\        <false/>
        \\        <key>Crashed</key>
        \\        <true/>
        \\    </dict>
        \\    <key>LimitLoadToSessionType</key>
        \\    <string>Aqua</string>
        \\    <key>ProcessType</key>
        \\    <string>Interactive</string>
        \\</dict>
        \\</plist>
        \\
    , .{ .label = launchd_label, .server = server_exe_name }));
}
