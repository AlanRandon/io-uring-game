const std = @import("std");
const protocol = @import("./protocol.zig");
const net = std.net;
const IoUring = @import("./io_uring.zig").IoUring;
const Game = @import("./game.zig").Game;
const Allocator = std.mem.Allocator;
const socket_t = std.posix.socket_t;

test {
    _ = .{
        @import("./game.zig"),
        @import("./protocol.zig"),
        @import("./io_uring.zig"),
    };
    std.testing.refAllDeclsRecursive(@This());
}

const Server = struct {
    const ClientMap = std.AutoHashMap(socket_t, *Client);
    const GameMap = std.AutoHashMap(u64, *GameSlot);

    allocator: Allocator,
    io_uring: IoUring,
    rng: std.Random.DefaultPrng,
    tcp: net.Server,
    clients: ClientMap,
    games: GameMap,

    fn init(addr: net.Address, allocator: Allocator) !Server {
        return .{
            .allocator = allocator,
            .io_uring = try IoUring.init(),
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
            .tcp = try addr.listen(.{ .reuse_address = true }),
            .clients = ClientMap.init(allocator),
            .games = GameMap.init(allocator),
        };
    }

    fn deinit(server: *Server) void {
        server.clients.deinit();
        server.tcp.deinit();
        server.games.deinit();
        server.io_uring.deinit();
    }

    const RunError = Allocator.Error || error{ IoUringWait, IoUringNoUserData };

    fn run(server: *Server) RunError!void {
        try server.io_uring.submitAccept(server.tcp.stream.handle, server.allocator);
        while (true) {
            switch (try server.io_uring.waitEvent()) {
                .event => |event| {
                    defer server.allocator.destroy(event);

                    switch (event.*) {
                        .accept => |accept| {
                            try server.io_uring.submitAccept(server.tcp.stream.handle, server.allocator);

                            const client = try server.allocator.create(Client);
                            client.* = .{ .state = .reading_connect, .socket = accept.socket };
                            try server.clients.put(accept.socket, client);

                            const buf = try server.allocator.alloc(u8, @sizeOf(protocol.Connect));
                            try server.io_uring.submitRead(accept.socket, buf, server.allocator);
                        },
                        .read => |read| {
                            defer server.allocator.free(read.buf);
                            if (server.clients.get(read.fd)) |client| {
                                try client.handle_message(server, read.buf);
                            }
                        },
                        .write => |write| {
                            defer server.allocator.free(write.buf);
                            if (server.clients.get(write.fd)) |client| {
                                try client.handle_message(server, write.buf);
                            }
                        },
                        .close => {},
                    }
                },
                .fail => |result| {
                    // Handle cleanup on errors (e.g. disconnects)
                    defer server.allocator.destroy(result.event);

                    switch (result.event.*) {
                        .read => |read| {
                            defer server.allocator.free(read.buf);
                            if (server.clients.get(read.fd)) |client| {
                                try server.destroyClient(client);
                            }
                        },
                        .write => |write| {
                            defer server.allocator.free(write.buf);
                            if (server.clients.get(write.fd)) |client| {
                                try server.destroyClient(client);
                            }
                        },
                        else => {},
                    }
                },
            }
        }
    }

    fn writeAny(server: *Server, socket: socket_t, data: anytype) !void {
        const response = try server.allocator.alignedAlloc(
            u8,
            @alignOf(@TypeOf(data)),
            @sizeOf(@TypeOf(data)),
        );
        @as(*@TypeOf(data), @ptrCast(response)).* = data;
        // std.debug.print("{s} {any}\n", .{ @typeName(@TypeOf(data)), response });
        try server.io_uring.submitWrite(socket, response, server.allocator);
    }

    fn destroyClient(server: *Server, client: *Client) !void {
        switch (client.state) {
            .playing => |playing| {
                defer server.allocator.destroy(playing.game);
                switch (playing.game.state) {
                    .waiting => {
                        defer server.allocator.destroy(client);
                        _ = server.clients.remove(client.socket);
                        try server.io_uring.submitClose(client.socket, server.allocator);
                    },
                    .playing => |game| {
                        for (game.clients) |c| {
                            defer server.allocator.destroy(c);
                            _ = server.clients.remove(c.socket);
                            try server.io_uring.submitClose(c.socket, server.allocator);
                        }
                        _ = server.games.remove(playing.game.id);
                    },
                }
            },
            .reading_connect, .writing_connected => {
                defer server.allocator.destroy(client);
                _ = server.clients.remove(client.socket);
                try server.io_uring.submitClose(client.socket, server.allocator);
            },
        }
    }
};

const GameSlot = struct {
    const Playing = struct {
        clients: [2]*Client,
        game: Game,
    };

    id: u64,
    state: union(enum) {
        waiting: *Client,
        playing: Playing,
    },

    fn join(slot: *GameSlot, player: *Client) !void {
        switch (slot.state) {
            .waiting => |p| {
                slot.state = .{ .playing = .{
                    .game = Game.init(),
                    .clients = [2]*Client{ p, player },
                } };
            },
            .playing => {
                return error.GameFull;
            },
        }
    }
};

const Client = struct {
    state: union(enum) {
        reading_connect,
        writing_connected,
        playing: struct {
            game: *GameSlot,
            player: @import("./game.zig").Player,
            state: enum { writing_started, writing_move_result, reading_move },
        },
    },
    socket: socket_t,

    fn handle_message(client: *Client, server: *Server, buf: []u8) !void {
        switch (client.state) {
            .reading_connect => {
                const connect: *protocol.Connect = @ptrCast(@alignCast(buf));
                client.state = .writing_connected;
                std.log.info("Read connect: {} {}", .{ client.socket, connect });

                switch (connect.*) {
                    .join => |join| {
                        if (server.games.get(join.id)) |game| {
                            game.join(client) catch |err| switch (err) {
                                error.GameFull => {
                                    try server.writeAny(client.socket, protocol.Connected{ .err = .game_full });
                                    return;
                                },
                            };

                            try server.writeAny(client.socket, protocol.Connected{ .success = .{ .id = join.id } });
                        } else {
                            try server.writeAny(client.socket, protocol.Connected{ .err = .game_not_exists });
                        }
                    },
                    .create => {
                        var id: u64 = undefined;
                        while (true) {
                            id = server.rng.next();
                            if (!server.games.contains(id)) {
                                const slot = try server.allocator.create(GameSlot);
                                slot.* = .{ .state = .{ .waiting = client }, .id = id };
                                try server.games.put(id, slot);

                                try server.writeAny(client.socket, protocol.Connected{ .success = .{ .id = id } });
                                return;
                            }
                        }
                    },
                }
            },
            .writing_connected => {
                const connected: *protocol.Connected = @ptrCast(@alignCast(buf));
                std.log.info("Wrote connected: {} {}", .{ client.socket, connected });

                switch (connected.*) {
                    .success => |success| {
                        if (server.games.get(success.id)) |game| {
                            switch (game.state) {
                                .playing => |playing| {
                                    inline for (playing.clients, .{ .x, .o }) |c, p| {
                                        c.state = .{ .playing = .{ .state = .writing_started, .game = game, .player = p } };
                                        try server.writeAny(c.socket, protocol.Started{ .player = p });
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    .err => {
                        try server.destroyClient(client);
                    },
                }
            },
            .playing => |*playing| {
                const game = &playing.game.state.playing;
                switch (playing.state) {
                    .writing_started => {
                        const started: *protocol.Started = @ptrCast(@alignCast(buf));
                        std.log.info("Wrote started: {} {}", .{ client.socket, started });

                        if (game.game.nextMovePlayer == playing.player) {
                            playing.state = .reading_move;
                            const move_buf = try server.allocator.alloc(u8, @sizeOf(protocol.Move));
                            try server.io_uring.submitRead(client.socket, move_buf, server.allocator);
                        }
                    },
                    .reading_move => {
                        const m: *protocol.Move = @ptrCast(@alignCast(buf));
                        std.log.info("Read move: {} {}", .{ client.socket, m });

                        const winner = game.game.tryMove(m.*) catch |err| switch (err) {
                            error.InvalidMove => {
                                client.state.playing.state = .writing_move_result;
                                const move_result: protocol.MoveResult = protocol.MoveResult.invalid_move;
                                try server.writeAny(client.socket, move_result);
                                std.log.info("Writing move result: {} {}", .{ client.socket, move_result });
                                return;
                            },
                        };

                        if (winner) |w| {
                            std.log.info("Winner: {}", .{w});
                        }

                        inline for (game.clients) |c| {
                            const p = &c.state.playing;
                            p.state = .writing_move_result;
                            try server.writeAny(c.socket, protocol.MoveResult{ .move = m.* });
                        }
                    },
                    .writing_move_result => {
                        const move: *protocol.MoveResult = @ptrCast(@alignCast(buf));
                        std.log.info("Wrote move result: {} {}", .{ client.socket, move });

                        if (game.game.nextMovePlayer == playing.player) {
                            playing.state = .reading_move;
                            const move_buf = try server.allocator.alloc(u8, @sizeOf(protocol.Move));
                            try server.io_uring.submitRead(client.socket, move_buf, server.allocator);
                        }
                    },
                }
            },
        }
    }
};

pub fn main() !void {
    var server = try Server.init(protocol.addr, std.heap.c_allocator);
    defer server.deinit();

    try server.run();
}
