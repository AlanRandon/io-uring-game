const std = @import("std");
const Game = @import("./game.zig").Game;
const net = std.net;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("liburing.h");
    @cInclude("string.h");
});

test {
    _ = .{@import("./game.zig")};
    std.testing.refAllDeclsRecursive(@This());
}

const IoUring = struct {
    ring: c.io_uring,
    allocator: Allocator,

    const Event = union(enum) {
        const Accept = struct { socket: std.posix.socket_t, addr: net.Address };
        const Read = struct { socket: std.posix.socket_t, buf: []u8 };
        const Write = struct { socket: std.posix.socket_t, buf: []u8 };

        accept: Accept,
        read: Read,
        write: Write,
    };

    fn init(allocator: Allocator) !IoUring {
        var ring: c.io_uring = undefined;
        if (c.io_uring_queue_init(256, &ring, 0) != 0) {
            return error.IoUringQueueInit;
        }

        return .{
            .ring = ring,
            .allocator = allocator,
        };
    }

    fn deinit(io_uring: *IoUring) void {
        c.io_uring_queue_exit(&io_uring.ring);
    }

    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

    fn submitAccept(
        io_uring: *IoUring,
        socket: std.posix.socket_t,
    ) !void {
        const sqe = c.io_uring_get_sqe(&io_uring.ring);

        const event = try io_uring.allocator.create(Event);
        event.* = Event{ .accept = .{ .socket = undefined, .addr = undefined } };
        c.io_uring_sqe_set_data(sqe, event);

        c.io_uring_prep_accept(
            sqe,
            socket,
            @ptrCast(&event.accept.addr.any),
            &addrlen,
            0,
        );

        _ = c.io_uring_submit(&io_uring.ring);
    }

    fn submitRead(
        io_uring: *IoUring,
        socket: std.posix.fd_t,
        buf: []u8,
    ) !void {
        const sqe = c.io_uring_get_sqe(&io_uring.ring);

        const event = try io_uring.allocator.create(Event);
        event.* = Event{ .read = .{ .socket = socket, .buf = buf } };
        c.io_uring_sqe_set_data(sqe, event);

        c.io_uring_prep_read(sqe, socket, buf.ptr, @intCast(buf.len), 0);
        _ = c.io_uring_submit(&io_uring.ring);
    }

    fn submitWrite(
        io_uring: *IoUring,
        socket: std.posix.fd_t,
        buf: []u8,
    ) !void {
        const sqe = c.io_uring_get_sqe(&io_uring.ring);

        const event = try io_uring.allocator.create(Event);
        event.* = Event{ .write = .{ .socket = socket, .buf = buf } };
        c.io_uring_sqe_set_data(sqe, event);

        c.io_uring_prep_write(sqe, socket, buf.ptr, @intCast(buf.len), 0);
        _ = c.io_uring_submit(&io_uring.ring);
    }

    fn waitEvent(io_uring: *IoUring) !union(enum) {
        event: *Event,
        fail: struct { event: *Event, code: c_int },
    } {
        var cqe: [*c]c.io_uring_cqe = undefined;
        if (c.io_uring_wait_cqe(&io_uring.ring, @as([*c][*c]c.io_uring_cqe, &cqe)) != 0) {
            return error.IoUringWait;
        }

        defer c.io_uring_cqe_seen(&io_uring.ring, cqe);

        const event: *Event = @ptrCast(@alignCast(c.io_uring_cqe_get_data(cqe) orelse return error.IoUringNoUserData));
        if (cqe.*.res < 0) {
            return .{ .fail = .{
                .event = event,
                .code = -cqe.*.res,
            } };
        }

        switch (event.*) {
            .accept => {
                event.accept.socket = cqe.*.res;
            },
            else => {},
        }

        return .{ .event = event };
    }
};

const Server = struct {
    allocator: Allocator,
    io_uring: IoUring,
    rng: std.Random.DefaultPrng,
    tcp: net.Server,
    clients: std.AutoHashMap(std.posix.socket_t, *Client),
    games: std.AutoHashMap(u64, *Game),

    fn init(addr: net.Address, allocator: Allocator) !Server {
        return .{
            .allocator = allocator,
            .io_uring = try IoUring.init(allocator),
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
            .tcp = try addr.listen(.{ .reuse_address = true }),
            .clients = std.AutoHashMap(std.posix.socket_t, *Client).init(allocator),
            .games = std.AutoHashMap(u64, *Game).init(allocator),
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
        try server.io_uring.submitAccept(server.tcp.stream.handle);
        while (true) {
            switch (try server.io_uring.waitEvent()) {
                .event => |event| {
                    defer server.allocator.destroy(event);
                    switch (event.*) {
                        .accept => |accept| {
                            const client = try server.allocator.create(Client);
                            client.* = .waiting_to_connect;
                            try server.clients.put(accept.socket, client);

                            try server.io_uring.submitAccept(server.tcp.stream.handle);
                            const buf = try server.allocator.alloc(u8, @sizeOf(ConnectToGame));
                            try server.io_uring.submitRead(accept.socket, buf);
                        },
                        .read => |read| {
                            if (server.clients.get(read.socket)) |client| {
                                try client.handle_event(server, read);
                            }
                        },
                        .write => |write| {
                            server.allocator.free(write.buf);
                        },
                    }
                },
                .fail => |result| {
                    // Handle cleanup on errors (e.g. disconnects)
                    defer server.allocator.destroy(result.event);
                    switch (result.event.*) {
                        .read => |read| {
                            if (server.clients.fetchRemove(read.socket)) |client| {
                                server.allocator.destroy(client.value);
                            }

                            server.allocator.free(read.buf);
                        },
                        .write => |write| {
                            if (server.clients.fetchRemove(write.socket)) |client| {
                                server.allocator.destroy(client.value);
                            }

                            server.allocator.free(write.buf);
                        },
                        else => {},
                    }
                },
            }
        }
    }
};

const Client = union(enum) {
    waiting_to_connect,
    waiting_for_peer: *Game,
    playing: *Game,

    fn handle_event(client: *Client, server: *Server, event: IoUring.Event.Read) Server.RunError!void {
        switch (client.*) {
            .waiting_to_connect => {
                defer server.allocator.free(event.buf);

                var id: u64 = undefined;
                const connect_to_game: *ConnectToGame = @ptrCast(@alignCast(event.buf));
                if (connect_to_game.game_id) |desired_id| {
                    if (server.games.get(desired_id)) |game| {
                        id = desired_id;
                        _ = game;
                    } else {
                        std.log.err("TODO: game id not exists", .{});
                        return;
                    }
                } else {
                    while (true) {
                        id = server.rng.next();
                        if (!server.games.contains(id)) {
                            const game = try server.allocator.create(Game);
                            game.* = Game.init();
                            try server.games.put(id, game);

                            client.* = .{ .waiting_for_peer = game };

                            break;
                        }
                    }
                }

                const response = try server.allocator.alloc(u8, @sizeOf(ConnectedToGame));
                @as(*ConnectedToGame, @ptrCast(@alignCast(response))).* = ConnectedToGame{ .id = id };
                try server.io_uring.submitWrite(event.socket, response);
            },
            else => {},
        }
    }
};

const ConnectToGame = struct { game_id: ?u64 };
const ConnectedToGame = struct { id: u64 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const addr = net.Address{ .in = try net.Ip4Address.parse("127.0.0.1", 8080) };
    var server = try Server.init(addr, allocator);
    defer server.deinit();

    try server.run();
}
