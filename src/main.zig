const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("liburing.h");
    @cInclude("string.h");
});

const IoUring = struct {
    ring: c.io_uring,
    allocator: Allocator,

    const Event = union(enum) {
        accept: struct { socket: std.posix.socket_t, addr: net.Address },
        read: struct { socket: std.posix.socket_t, buf: []u8 },
        write: struct { socket: std.posix.socket_t, buf: []u8 },
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
        socket: std.posix.socket_t,
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
        socket: std.posix.socket_t,
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const addr = net.Address{ .in = try net.Ip4Address.parse("127.0.0.1", 8080) };
    const server = try addr.listen(.{ .reuse_address = true });

    var io_uring = try IoUring.init(allocator);
    defer io_uring.deinit();

    try io_uring.submitAccept(server.stream.handle);
    while (true) {
        switch (try io_uring.waitEvent()) {
            .event => |event| {
                defer allocator.destroy(event);
                switch (event.*) {
                    .accept => |accept| {
                        try io_uring.submitAccept(server.stream.handle);
                        const buf = try allocator.alloc(u8, 1);
                        try io_uring.submitRead(accept.socket, buf);
                    },
                    .read => |read| {
                        // std.log.debug("Read {s}", .{read.buf});
                        try io_uring.submitWrite(read.socket, read.buf);
                    },
                    .write => |write| {
                        try io_uring.submitRead(write.socket, write.buf);
                    },
                }
            },
            .fail => |result| {
                // Handle cleanup on errors (e.g. disconnects)
                // std.log.info("{s}", .{c.strerror(result.code)});
                switch (result.event.*) {
                    .read => |read| {
                        allocator.free(read.buf);
                    },
                    .write => |write| {
                        allocator.free(write.buf);
                    },
                    else => {},
                }
                allocator.destroy(result.event);
            },
        }
    }
}
