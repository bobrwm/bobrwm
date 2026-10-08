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
    /// Print a configuration in config file format.
    ///
    /// Without flags this prints the options your config file changes from
    /// the defaults, as bobrwm reads them. If your config file is invalid, it
    /// prints the errors and exits non-zero instead.
    ///
    /// To see every option with its documentation and default value, run
    /// `bobrwm show-config --default --docs`. Do not save that output as your
    /// config: it pins every default, so you would miss improved defaults in
    /// later releases. Set only the options you want to change.
    ///
    /// Flags:
    ///
    ///   --default  Print every option at its built-in default instead of
    ///              loading your config file.
    ///
    ///   --docs     Print each option's documentation above it as a comment.
    @"show-config",

    /// Usage: bobrwm migrate-config
    ///
    /// Convert a `config.zon` from an earlier bobrwm into the current config
    /// file format, next to it at `~/.config/bobrwm/config` (or under
    /// `$XDG_CONFIG_HOME`). Only options that differ from the defaults are
    /// written, and `workspace_assignments` entries become `app-rule` lines.
    ///
    /// Refuses to overwrite an existing config file. The old `config.zon` is
    /// left in place; delete it once the new file looks right.
    @"migrate-config",

    /// Usage: bobrwm list-actions [--docs]
    ///
    /// List the actions a `keybind` line can run: the part after the
    /// trigger's `=`, as in `keybind = alt+h=focus_left`.
    ///
    /// Flags:
    ///
    ///   --docs  Print each action's documentation below it.
    @"list-actions",

    pub fn parse(name: []const u8) ?Command {
        return std.meta.stringToEnum(Command, name);
    }
};
