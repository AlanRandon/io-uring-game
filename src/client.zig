const std = @import("std");
const Game = @import("./game.zig").Game;
const protocol = @import("./protocol.zig");
const net = std.net;
const assert = std.debug.assert;

fn bytesConst(comptime T: type, data: *const T) []const u8 {
    return @as([*]const u8, @ptrCast(data))[0..@sizeOf(T)];
}

fn bytes(comptime T: type, data: *T) []u8 {
    return @as([*]u8, @ptrCast(data))[0..@sizeOf(T)];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var game = Game.init();
    var args = std.process.args();
    _ = args.skip();

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

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdOut().reader();

    try stdout.print("{}\n", .{id});

    var started: protocol.Started = undefined;
    _ = try connection.readAll(bytes(protocol.Started, &started));

    const player = started.player;

    switch (player) {
        .o => try stdout.print("Os\n", .{}),
        .x => try stdout.print("Xs\n", .{}),
    }

    var move: protocol.Move = undefined;
    while (true) {
        try stdout.print("{}", .{game});

        if (game.nextMovePlayer == player) {
            const subgrid = if (game.nextMoveSubgrid) |g| @as(u4, @intCast(g)) else blk: {
                try stdout.print("Grid: ", .{});
                const subgrid_line = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 10) orelse return error.NoInput;
                break :blk try std.fmt.parseInt(u4, subgrid_line, 10);
            };

            try stdout.print("Cell: ", .{});
            const cell_line = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 10) orelse return error.NoInput;
            const cell = try std.fmt.parseInt(u4, cell_line, 10);

            move = .{ .player = player, .subgrid = subgrid, .cell = cell };

            try connection.writeAll(bytesConst(protocol.Move, &move));
            try stdout.print("Sent\n", .{});
        }

        var move_result: protocol.MoveResult = undefined;
        _ = try connection.readAll(bytes(protocol.MoveResult, &move_result));
        std.debug.print("Read {}\n", .{move_result});

        switch (move_result) {
            .invalid_move => {
                std.debug.print("Invalid Move\n", .{});
                assert(game.nextMovePlayer == player);
                continue;
            },
            .move => |m| {
                const winner = game.tryMove(m) catch @panic("Server sent invalid move");
                if (winner) |w| {
                    std.debug.panic("TODO: winner {}", .{w});
                }
            },
        }
    }
}
