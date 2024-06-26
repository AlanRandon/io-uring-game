const std = @import("std");
const protocol = @import("./protocol.zig");
const net = std.net;
const IoUring = @import("./io_uring.zig").IoUring;
const Game = @import("./game.zig").Game;
const Player = @import("./game.zig").Player;
const Allocator = std.mem.Allocator;
const socket_t = std.posix.socket_t;
const assert = std.debug.assert;

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
    const WaitingClients = std.AutoHashMap(u64, *Client);

    allocator: Allocator,
    io_uring: IoUring,
    rng: std.Random.DefaultPrng,
    tcp: net.Server,
    clients: ClientMap,
    waiting_clients: WaitingClients,

    fn init(addr: net.Address, allocator: Allocator) !Server {
        return .{
            .allocator = allocator,
            .io_uring = try IoUring.init(),
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
            .tcp = try addr.listen(.{ .reuse_address = true }),
            .clients = ClientMap.init(allocator),
            .waiting_clients = WaitingClients.init(allocator),
        };
    }

    fn deinit(server: *Server) void {
        server.clients.deinit();
        server.waiting_clients.deinit();
        server.tcp.deinit();
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
                                try client.handleMessage(server, read.buf);
                            }
                        },
                        .write => |write| {
                            defer server.allocator.free(write.buf);
                            if (server.clients.get(write.fd)) |client| {
                                try client.handleMessage(server, write.buf);
                            }
                        },
                        .close => |close| {
                            std.log.info("Closed {}", .{close.fd});
                        },
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
        const response = try server.allocator.alignedAlloc(u8, @alignOf(@TypeOf(data)), @sizeOf(@TypeOf(data)));
        @as(*@TypeOf(data), @ptrCast(response)).* = data;
        try server.io_uring.submitWrite(socket, response, server.allocator);
    }

    fn destroyClient(server: *Server, client: *Client) !void {
        if (client.getPlayingState()) |g| {
            const game = g.*;
            defer server.allocator.destroy(game.game);
            for ([_]*Client{ client, game.opponent }) |c| {
                defer server.allocator.destroy(c);
                _ = server.clients.remove(c.socket);
                try server.io_uring.submitClose(c.socket, server.allocator);
            }
        } else {
            defer server.allocator.destroy(client);
            _ = server.clients.remove(client.socket);
            try server.io_uring.submitClose(client.socket, server.allocator);
        }
    }
};

const Client = struct {
    const PlayingState = struct {
        game: *Game,
        opponent: *Client,
        player: Player,
    };

    state: union(enum) {
        reading_connect,
        writing_connected_error,
        writing_connected_waiting,
        writing_connected_joined: PlayingState,
        writing_started: PlayingState,
        writing_move_result: PlayingState,
        reading_move: PlayingState,
    },
    socket: socket_t,

    fn getPlayingState(client: *Client) ?*PlayingState {
        return switch (client.state) {
            .writing_connected_joined, .writing_started, .writing_move_result, .reading_move => |*game| game,
            .reading_connect, .writing_connected_error, .writing_connected_waiting => null,
        };
    }

    fn connectRead(client: *Client, server: *Server, connect: protocol.Connect) !void {
        switch (connect) {
            .join => |join| {
                if (server.waiting_clients.fetchRemove(join.id)) |opponent| {
                    const game = try server.allocator.create(Game);
                    game.* = Game.init();

                    const players = if (server.rng.next() % 2 == 0) [2]Player{ .x, .o } else [2]Player{ .o, .x };

                    client.state = .{ .writing_connected_joined = .{
                        .game = game,
                        .opponent = opponent.value,
                        .player = players[0],
                    } };

                    opponent.value.state = .{ .writing_connected_joined = .{
                        .game = game,
                        .opponent = client,
                        .player = players[1],
                    } };

                    try server.writeAny(client.socket, protocol.Connected{ .success = .{ .id = join.id } });
                } else {
                    client.state = .writing_connected_error;

                    try server.writeAny(client.socket, protocol.Connected{ .err = .game_not_exists });
                }
            },
            .create => {
                client.state = .writing_connected_waiting;

                var id: u64 = undefined;
                while (true) {
                    id = server.rng.next();
                    if (!server.waiting_clients.contains(id)) {
                        try server.waiting_clients.put(id, client);

                        try server.writeAny(client.socket, protocol.Connected{ .success = .{ .id = id } });
                        return;
                    }
                }
            },
        }
    }

    fn moveRead(client: *Client, server: *Server, move: *protocol.Move, game: PlayingState) !void {
        move.player = client.getPlayingState().?.player;
        client.state = .{ .writing_move_result = game };

        const winner = game.game.tryMove(move.*) catch |err| switch (err) {
            error.InvalidMove => {
                const move_result: protocol.MoveResult = protocol.MoveResult.invalid_move;
                try server.writeAny(client.socket, move_result);
                return;
            },
        };

        if (winner) |w| {
            std.log.info("Winner: {}", .{w});
            try server.destroyClient(client);
            return;
        }

        game.opponent.state = .{ .writing_move_result = game.opponent.getPlayingState().?.* };
        try server.writeAny(client.socket, protocol.MoveResult{ .move = move.* });
        try server.writeAny(game.opponent.socket, protocol.MoveResult{ .move = move.* });
    }

    fn handleMessage(client: *Client, server: *Server, buf: []u8) !void {
        switch (client.state) {
            .reading_connect => {
                assert(buf.len == @sizeOf(protocol.Connect));
                const connect: *protocol.Connect = @ptrCast(@alignCast(buf));
                std.log.info("Read connect: {} {}", .{ client.socket, connect });
                try client.connectRead(server, connect.*);
            },
            .writing_connected_error => {
                assert(buf.len == @sizeOf(protocol.Connected));
                const connected: *protocol.Connected = @ptrCast(@alignCast(buf));
                std.log.info("Wrote connected (errored): {} {}", .{ client.socket, connected });
                try server.destroyClient(client);
            },
            .writing_connected_waiting => {
                assert(buf.len == @sizeOf(protocol.Connected));
                const connected: *protocol.Connected = @ptrCast(@alignCast(buf));
                std.log.info("Wrote connected (waiting): {} {}", .{ client.socket, connected });
            },
            .writing_connected_joined => |game| {
                assert(buf.len == @sizeOf(protocol.Connected));
                const connected: *protocol.Connected = @ptrCast(@alignCast(buf));
                std.log.info("Wrote connected (joined): {} {}", .{ client.socket, connected });

                inline for (.{ client, game.opponent }) |c| {
                    const state = c.state.writing_connected_joined;
                    c.state = .{ .writing_started = state };
                    try server.writeAny(c.socket, protocol.Started{ .player = state.player });
                }
            },
            .writing_started => |game| {
                assert(buf.len == @sizeOf(protocol.Started));
                const started: *protocol.Started = @ptrCast(@alignCast(buf));
                std.log.info("Wrote started: {} {}", .{ client.socket, started });

                if (game.game.nextMovePlayer == game.player) {
                    client.state = .{ .reading_move = game };
                    const move_buf = try server.allocator.alloc(u8, @sizeOf(protocol.Move));
                    try server.io_uring.submitRead(client.socket, move_buf, server.allocator);
                }
            },
            .reading_move => |game| {
                assert(buf.len == @sizeOf(protocol.Move));
                const move: *protocol.Move = @ptrCast(@alignCast(buf));
                std.log.info("Read move: {} {}", .{ client.socket, move });
                try client.moveRead(server, move, game);
            },
            .writing_move_result => |game| {
                assert(buf.len == @sizeOf(protocol.MoveResult));
                const move: *protocol.MoveResult = @ptrCast(@alignCast(buf));
                std.log.info("Wrote move result: {} {}", .{ client.socket, move });

                if (game.game.nextMovePlayer == game.player) {
                    client.state = .{ .reading_move = game };
                    const move_buf = try server.allocator.alloc(u8, @sizeOf(protocol.Move));
                    try server.io_uring.submitRead(client.socket, move_buf, server.allocator);
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
