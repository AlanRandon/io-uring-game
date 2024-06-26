const std = @import("std");
const Game = @import("./game.zig").Game;
const protocol = @import("./protocol.zig");
const ansi = @import("./ansi.zig");
const net = std.net;
const assert = std.debug.assert;

fn bytesConst(comptime T: type, data: *const T) []const u8 {
    return @as([*]const u8, @ptrCast(data))[0..@sizeOf(T)];
}

fn bytes(comptime T: type, data: *T) []u8 {
    return @as([*]u8, @ptrCast(data))[0..@sizeOf(T)];
}

const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

const UI = struct {
    raw_mode: ansi.RawMode,

    fn init() !UI {
        const raw_mode = try ansi.RawMode.init(stdin.context);
        try stdout.writeAll(ansi.enter_alternate_screen ++ ansi.hide_cursor ++ ansi.clear);

        return .{ .raw_mode = raw_mode };
    }

    fn deinit(ui: *UI) void {
        stdout.writeAll(ansi.leave_alternate_screen ++ ansi.show_cursor) catch {};
        ui.raw_mode.deinit();
    }

    fn getCell(stdin_byte: *StdinByte) !u4 {
        stdin_byte.clear();

        while (true) {
            std.time.sleep(1000000);
            return switch (stdin_byte.readByte() orelse 0) {
                '1' => @as(u4, 0),
                '2' => 1,
                '3' => 2,
                '4' => 3,
                '5' => 4,
                '6' => 5,
                '7' => 6,
                '8' => 7,
                '9' => 8,
                else => continue,
            };
        }
    }

    fn renderJoinCode(id: u64) !void {
        try stdout.writeAll(ansi.clear ++ "⚡ Tic-tac-toe Ultimate ⚡\n");
        try stdout.print("Join Code: " ++ ansi.bold ++ "{}" ++ ansi.reset, .{id});
    }

    fn renderWin() !void {
        try stdout.writeAll(ansi.clear ++ "⚡ Tic-tac-toe Ultimate ⚡\n");
        try stdout.writeAll("You WON, press any key to exit\n");
    }

    fn renderLoss() !void {
        try stdout.writeAll(ansi.clear ++ "⚡ Tic-tac-toe Ultimate ⚡\n");
        try stdout.writeAll("You LOST, press any key to exit\n");
    }

    fn renderGameWithStatus(game: *Game, status: []const u8) !void {
        try stdout.writeAll(ansi.clear ++ "⚡ Tic-tac-toe Ultimate ⚡\n");
        try renderGame(game);
        try stdout.writeAll(status);
    }

    fn renderGame(game: *Game) !void {
        const dividers = [_][]const u8{
            "╭─────┬─────┬─────╮\n",
            "├─────┼─────┼─────┤\n",
            "├─────┼─────┼─────┤\n",
            "╰─────┴─────┴─────╯\n",
        };

        try stdout.writeAll(dividers[0]);
        for (0..9) |r| {
            try stdout.writeAll("│ ");
            for (0..9) |c| {
                const cell_index = (r % 3) * 3 + c % 3;
                const grid_index = (r / 3) * 3 + (c / 3);
                const cell = switch (game.grid[grid_index]) {
                    .playing => |grid| if (grid[cell_index]) |p| switch (p) {
                        .x => "X",
                        .o => "O",
                    } else "?",
                    .won => |player| if (cell_index == 4) switch (player) {
                        .x => "X",
                        .o => "O",
                    } else " ",
                };

                if (game.nextMoveSubgrid orelse grid_index == grid_index) {
                    try stdout.print(ansi.bold ++ "{s}" ++ ansi.reset, .{cell});
                } else {
                    try stdout.writeAll(cell);
                }

                if ((c + 1) % 3 == 0) {
                    try stdout.writeAll(" │ ");
                }
            }
            try stdout.writeAll("\n");

            if ((r + 1) % 3 == 0) {
                try stdout.writeAll(dividers[(r + 1) / 3]);
            }
        }

        if (game.nextMoveSubgrid) |subgrid| {
            try stdout.print("Next move must be in grid {?}\n", .{subgrid + 1});
        }
    }
};

const StdinByte = struct {
    byte: std.atomic.Value(u8),

    fn clear(stdin_byte: *StdinByte) void {
        stdin_byte.byte.store(0, .seq_cst);
    }

    fn readByte(stdin_byte: *StdinByte) ?u8 {
        const byte = stdin_byte.byte.load(.seq_cst);
        return if (byte == 0) null else byte;
    }

    fn startLoop(stdin_byte: *StdinByte, ui: *UI) !void {
        _ = try std.Thread.spawn(.{}, struct {
            fn readLoop(b: anytype, u: anytype) !void {
                while (true) {
                    const byte = try stdin.readByte();
                    if (byte == 'q') {
                        u.deinit();
                        stdout.writeAll("Killed: q pressed\n") catch {};
                        std.posix.exit(1);
                    }
                    b.byte.store(byte, .seq_cst);
                }
            }
        }.readLoop, .{ stdin_byte, ui });
    }
};

pub fn main() !void {
    var game = Game.init();
    var args = std.process.args();
    _ = args.skip();

    var ui = try UI.init();
    defer ui.deinit();

    var stdin_byte = StdinByte{ .byte = std.atomic.Value(u8).init(0) };
    try stdin_byte.startLoop(&ui);

    const connection = try net.tcpConnectToAddress(protocol.addr);
    defer connection.close();

    const connect: protocol.Connect = if (args.next()) |arg| .{
        .join = .{ .id = try std.fmt.parseInt(u64, arg, 10) },
    } else .create;
    try connection.writeAll(bytesConst(protocol.Connect, &connect));

    var connected: protocol.Connected = undefined;
    _ = try connection.readAll(bytes(protocol.Connected, &connected));

    const id = switch (connected) {
        .success => |c| c.id,
        .err => return error.FailedToConnect,
    };

    try UI.renderJoinCode(id);

    var started: protocol.Started = undefined;
    _ = try connection.readAll(bytes(protocol.Started, &started));

    const player = started.player;

    var move: protocol.Move = undefined;
    while (true) {
        const old_subgrid = game.nextMoveSubgrid;
        if (game.nextMovePlayer == player) {
            const p = switch (player) {
                .o => "[O]",
                .x => "[X]",
            };

            const moves =
                \\
                \\1 2 3
                \\4 5 6
                \\7 8 9
            ;

            const subgrid: u4 = if (game.nextMoveSubgrid) |g| @intCast(g) else blk: {
                try UI.renderGameWithStatus(&game, p ++ ": Choose a grid (1-9)\n" ++ moves);
                break :blk try UI.getCell(&stdin_byte);
            };
            game.nextMoveSubgrid = subgrid;

            try UI.renderGameWithStatus(&game, p ++ ": Choose a cell (1-9)\n" ++ moves);
            const cell = try UI.getCell(&stdin_byte);

            move = .{ .player = player, .subgrid = subgrid, .cell = cell };
            try connection.writeAll(bytesConst(protocol.Move, &move));
        } else {
            try UI.renderGameWithStatus(&game, "Waiting for opponent...");
        }

        var move_result: protocol.MoveResult = undefined;
        _ = try connection.readAll(bytes(protocol.MoveResult, &move_result));

        switch (move_result) {
            .invalid_move => {
                game.nextMoveSubgrid = old_subgrid;
                continue;
            },
            .move => |m| {
                const winner = game.tryMove(m) catch {
                    stdout.writeAll("Killed: server sent invalid move\n") catch {};
                    ui.deinit();
                    std.posix.exit(1);
                };

                if (winner) |w| {
                    if (w == player) {
                        try UI.renderWin();
                    } else {
                        try UI.renderLoss();
                    }
                    std.time.sleep(3000000000);
                    return;
                }
            },
        }
    }
}
