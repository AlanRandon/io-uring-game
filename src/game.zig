const std = @import("std");

pub const Player = enum(u1) { o, x };

const SubGrid = union(enum) {
    playing: [9]?Player,
    won: Player,
};

fn getCellWinner(comptime T: type, cell: *T) ?Player {
    if (T == ?Player) {
        return cell.*;
    } else if (T == SubGrid) {
        switch (cell.*) {
            .playing => {
                if (getGridWinner(?Player, &cell.playing)) |winner| {
                    cell.* = SubGrid{ .won = winner };
                    return winner;
                } else {
                    return null;
                }
            },
            .won => |value| {
                return value;
            },
        }
    } else {
        @compileError(std.fmt.comptimePrint("Invalid cell: {s}", .{@typeName(*T)}));
    }
}

fn getGridWinner(comptime T: type, grid: *[9]T) ?Player {
    var cells: [9]?Player = undefined;

    for (0..9) |i| {
        cells[i] = getCellWinner(T, &grid[i]);
    }

    for ([_][3]usize{
        .{ 0, 1, 2 },
        .{ 3, 4, 5 },
        .{ 6, 7, 8 },
        .{ 0, 3, 6 },
        .{ 1, 4, 7 },
        .{ 2, 5, 8 },
        .{ 0, 4, 8 },
        .{ 2, 4, 6 },
    }) |row| {
        const a = cells[row[0]] orelse continue;
        const b = cells[row[1]] orelse continue;
        const c = cells[row[2]] orelse continue;

        if (a == b and b == c) {
            return a;
        }
    }
    return null;
}

test "check grid winner" {
    {
        var grid = [_]?Player{
            .o, null, .o, //
            null, .o, null, //
            .x, null, .x, //
        };
        try std.testing.expectEqual(null, getGridWinner(?Player, &grid));
    }

    {
        var grid = [_]?Player{
            null, null, null, //
            .x, .x, .x, //
            null, null, null, //
        };
        try std.testing.expectEqual(.x, getGridWinner(?Player, &grid));
    }

    {
        var grid = [_]?Player{
            .o, null, .x, //
            null, .o, .x, //
            null, .x, .o, //
        };
        try std.testing.expectEqual(.o, getGridWinner(?Player, &grid));
    }

    {
        var grid = SubGrid{
            .playing = [_]?Player{
                .o, null, .x, //
                null, .o, .x, //
                null, .x, .x, //
            },
        };
        try std.testing.expectEqual(.x, getCellWinner(SubGrid, &grid));
        try std.testing.expectEqual(SubGrid{ .won = .x }, grid);
    }
}

pub const Move = packed struct {
    player: Player,
    subgrid: u4,
    cell: u4,
};

pub const Game = struct {
    grid: [9]SubGrid,
    nextMoveSubgrid: ?usize,
    nextMovePlayer: Player,

    pub fn init() Game {
        return .{
            .grid = [_]SubGrid{.{ .playing = [_]?Player{null} ** 9 }} ** 9,
            .nextMoveSubgrid = null,
            .nextMovePlayer = .x,
        };
    }

    pub fn tryMove(game: *Game, move: Move) !?Player {
        if (game.nextMovePlayer != move.player) {
            return error.InvalidMove;
        }

        if (game.nextMoveSubgrid) |subgrid| {
            if (subgrid != move.subgrid) {
                return error.InvalidMove;
            }
        }

        if (move.subgrid >= 9 or move.cell >= 9) {
            return error.InvalidMove;
        }

        switch (game.grid[move.subgrid]) {
            .playing => |playing| {
                if (playing[move.cell] != null) {
                    return error.InvalidMove;
                }

                game.grid[move.subgrid].playing[move.cell] = move.player;
            },
            .won => {
                return error.InvalidMove;
            },
        }

        if (getGridWinner(SubGrid, &game.grid)) |winner| {
            return winner;
        }

        game.nextMovePlayer = switch (move.player) {
            .o => .x,
            .x => .o,
        };

        switch (game.grid[move.subgrid]) {
            .playing => {
                game.nextMoveSubgrid = move.cell;
            },
            .won => {
                game.nextMoveSubgrid = null;
            },
        }

        return null;
    }

    pub fn format(
        self: Game,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("+---" ** 3 ++ "+\n");
        for (0..3) |subgrid_offset| {
            for (0..3) |row_offset| {
                try writer.writeAll("|");
                for (0 + subgrid_offset * 3..3 + subgrid_offset * 3) |subgrid| {
                    switch (self.grid[subgrid]) {
                        .playing => |playing| {
                            for (0 + row_offset * 3..3 + row_offset * 3) |cell| {
                                if (playing[cell]) |c| {
                                    switch (c) {
                                        .x => try writer.writeAll("x"),
                                        .o => try writer.writeAll("o"),
                                    }
                                } else {
                                    try writer.print("{}", .{cell});
                                }
                            }
                        },
                        .won => |c| {
                            if (row_offset == 1) {
                                try writer.print(" {s} ", .{switch (c) {
                                    .x => "x",
                                    .o => "o",
                                }});
                            } else {
                                try writer.writeAll("   ");
                            }
                        },
                    }
                    try writer.writeAll("|");
                }

                try writer.writeAll("\n");
            }
            try writer.writeAll("+---" ** 3 ++ "+\n");
        }
    }
};

test "game plays" {
    var game = Game.init();

    try std.testing.expectEqual(null, game.tryMove(.{
        .player = .x,
        .subgrid = 5,
        .cell = 5,
    }));

    try std.testing.expectError(error.InvalidMove, game.tryMove(.{
        .player = .x,
        .subgrid = 5,
        .cell = 5,
    }));

    for ([_]Move{
        .{ .player = .o, .subgrid = 5, .cell = 0 },
        .{ .player = .x, .subgrid = 0, .cell = 5 },
        .{ .player = .o, .subgrid = 5, .cell = 1 },
        .{ .player = .x, .subgrid = 1, .cell = 5 },
        .{ .player = .o, .subgrid = 5, .cell = 2 },
    }) |move| {
        try std.testing.expectEqual(null, game.tryMove(move));
    }

    try std.testing.expectEqual(.o, game.grid[5].won);
}
