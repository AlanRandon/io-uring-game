const std = @import("std");
const posix = std.posix;

const csi = "\u{1b}[";

pub const show_cursor = csi ++ "?25h";
pub const hide_cursor = csi ++ "?25l";
pub const cursor_to_top_left = csi ++ "0;0H";

pub const enter_alternate_screen = csi ++ "?1049h";
pub const leave_alternate_screen = csi ++ "?1049l";
pub const clear = csi ++ "2J" ++ cursor_to_top_left;
pub const clear_line = csi ++ "2K" ++ csi ++ "0G";

pub const reset = csi ++ "0m";
pub const bold = csi ++ "1m";
pub const invert = csi ++ "7m";

pub const fg = struct {
    pub const black = csi ++ "30m";
    pub const red = csi ++ "31m";
    pub const green = csi ++ "32m";
    pub const yellow = csi ++ "33m";
    pub const blue = csi ++ "34m";
    pub const magenta = csi ++ "35m";
    pub const cyan = csi ++ "35m";
    pub const white = csi ++ "37m";

    pub fn rgb(
        comptime r: u8,
        comptime g: u8,
        comptime b: u8,
    ) []const u8 {
        return std.fmt.comptimePrint(csi ++ "38;2;{};{};{}m", .{ r, g, b });
    }
};

pub const bg = struct {
    pub const black = csi ++ "40m";
    pub const red = csi ++ "41m";
    pub const green = csi ++ "42m";
    pub const yellow = csi ++ "43m";
    pub const blue = csi ++ "44m";
    pub const magenta = csi ++ "45m";
    pub const cyan = csi ++ "45m";
    pub const white = csi ++ "47m";

    pub fn rgb(
        comptime r: u8,
        comptime g: u8,
        comptime b: u8,
    ) []const u8 {
        return std.fmt.comptimePrint(csi ++ "48;2;{};{};{}m", .{ r, g, b });
    }
};

pub const RawMode = struct {
    original_termios: posix.termios,
    stdin: std.fs.File,

    pub fn init(stdin: std.fs.File) !RawMode {
        const original_termios = try posix.tcgetattr(stdin.handle);

        var termios: posix.termios = original_termios;
        termios.lflag.ICANON = false; // disable line buffering
        termios.lflag.ECHO = false; // disable echo
        termios.lflag.ISIG = false; // disable Ctrl-C and Ctrl-Z
        _ = try posix.tcsetattr(stdin.handle, std.posix.TCSA.NOW, termios);

        return .{
            .original_termios = original_termios,
            .stdin = stdin,
        };
    }

    pub fn deinit(self: *const RawMode) void {
        posix.tcsetattr(
            self.stdin.handle,
            posix.TCSA.NOW,
            self.original_termios,
        ) catch {};
    }
};
