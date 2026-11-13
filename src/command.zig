//! Commands the `bobrwm` client handles itself instead of forwarding to the
//! running window manager. The doc comment on each tag is the text that
//! `bobrwm <command> --help` prints; helpgen extracts it at build time.
//!
//! Lives outside `cli.zig` because helpgen imports it, and `cli.zig` depends
//! on generated build options helpgen does not have.

const std = @import("std");

pub const Command = enum {
    /// Usage: bobrwm help
    ///
    /// Show general help, including the commands forwarded to the running
    /// window manager. Same as `bobrwm --help`.
    ///
    /// Run `bobrwm <command> --help` for help on a specific command.
    help,

    /// Usage: bobrwm version
    ///
    /// Print the bobrwm version. Same as `bobrwm --version`.
    version,

    /// Usage: bobrwm show-config [--default] [--docs]
    ///
    /// Print the configuration as `init.lua`.
    ///
    /// Without flags this prints the configuration bobrwm loads, merged from
    /// `init.lua` and the settings window, with every option spelled out,
    /// including ones left at their default. If the config is invalid, it
    /// prints the errors and exits non-zero instead.
    ///
    /// New to bobrwm? Start a config from every option with its
    /// documentation:
    ///
    ///     bobrwm show-config --default --docs > ~/.config/bobrwm/init.lua
    ///
    /// Flags:
    ///
    ///   --default  Print the built-in defaults instead of loading your
    ///              config.
    ///
    ///   --docs     Print each option's documentation above it as a comment.
    @"show-config",

    /// Usage: bobrwm check-config
    ///
    /// Load the config without applying it and report any mistakes, each
    /// with the file and line it is on. A bad `bobrwm.*` call is skipped and
    /// the rest still loads; a Lua error, such as a syntax error, fails the
    /// whole load, and the running window manager keeps its last good
    /// config.
    ///
    /// Exits non-zero if there are any errors.
    @"check-config",

    /// Usage: bobrwm migrate-config [--print]
    ///
    /// Convert `config.zon`, the config format before `init.lua`, into
    /// `init.lua`. bobrwm does this on its own at startup when only
    /// `config.zon` exists. `config.zon` is left in place, and an existing
    /// `init.lua` is never overwritten.
    ///
    /// Flags:
    ///
    ///   --print  Print the converted config instead of writing `init.lua`.
    @"migrate-config",

    /// Usage: bobrwm list-actions [--docs]
    ///
    /// List the actions a keybind can run, the second argument of
    /// `bobrwm.keymap.set`.
    ///
    /// Flags:
    ///
    ///   --docs  Print each action's documentation below it.
    @"list-actions",

    pub fn parse(name: []const u8) ?Command {
        return std.meta.stringToEnum(Command, name);
    }
};
