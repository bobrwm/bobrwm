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
    /// Print the configuration in `config.zon` format.
    ///
    /// Without flags this prints the configuration bobrwm loads from your
    /// config file, with every option spelled out, including ones left at
    /// their default. If your config file is invalid, it prints the errors
    /// and exits non-zero instead.
    ///
    /// New to bobrwm? Start a config from every option with its
    /// documentation:
    ///
    ///     bobrwm show-config --default --docs > ~/.config/bobrwm/config.zon
    ///
    /// Flags:
    ///
    ///   --default  Print the built-in defaults instead of loading your
    ///              config file.
    ///
    ///   --docs     Print each option's documentation above it as a comment.
    @"show-config",

    /// Usage: bobrwm list-actions [--docs]
    ///
    /// List the actions a keybind can run, the values of `.action` in a
    /// `.keybinds` entry.
    ///
    /// Flags:
    ///
    ///   --docs  Print each action's documentation below it.
    @"list-actions",

    pub fn parse(name: []const u8) ?Command {
        return std.meta.stringToEnum(Command, name);
    }
};
