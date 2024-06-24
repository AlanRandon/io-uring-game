const std = @import("std");
const game = @import("./game.zig");

pub const addr = std.net.Address{ .in = std.net.Ip4Address.parse("127.0.0.1", 8080) catch unreachable };

pub const Connect = union(Tag) {
    const Tag = enum(u1) { create, join };

    create,
    join: struct { id: u64 },
};

pub const Connected = union(Tag) {
    const Tag = enum(u1) { success, err };

    success: struct { id: u64 },
    err: enum(u8) { game_not_exists, game_full, unknown, _ },
};

pub const Started = struct { player: game.Player };

pub const Move = game.Move;

pub const MoveResult = union(Tag) {
    const Tag = enum(u1) { invalid_move, move };

    invalid_move,
    move: game.Move,
};

// fn isValid(self: *ConnectedToGame) bool {
//     return switch (@as(Tag, self.*)) {
//         .success, .err => true,
//         _ => false,
//     };
// }
//
// test "bit cast non-exhaustive union" {
//     var bits: [@sizeOf(ConnectedToGame)]u8 = undefined;
//     @memset(&bits, 255);
//     const connected_to_game: *ConnectedToGame = @ptrCast(@alignCast(&bits));
//     try std.testing.expect(!connected_to_game.isValid());
//     connected_to_game.* = .{ .success = .{ .code = 0 } };
//     try std.testing.expect(connected_to_game.isValid());
// }
