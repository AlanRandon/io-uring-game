const std = @import("std");
const Allocator = std.mem.Allocator;
const socket_t = std.posix.socket_t;
const fd_t = std.posix.fd_t;

const c = @cImport({
    @cInclude("liburing.h");
});

pub const IoUring = struct {
    ring: c.io_uring,

    const Event = union(enum) {
        const Accept = struct { socket: socket_t, addr: std.net.Address };
        const Read = struct { fd: fd_t, buf: []u8 };
        const Write = struct { fd: fd_t, buf: []u8 };
        const Close = struct { fd: fd_t };

        accept: Accept,
        read: Read,
        write: Write,
        close: Close,
    };

    pub fn init() !IoUring {
        var ring: c.io_uring = undefined;
        if (c.io_uring_queue_init(256, &ring, 0) != 0) {
            return error.IoUringQueueInit;
        }

        return .{ .ring = ring };
    }

    pub fn deinit(io_uring: *IoUring) void {
        c.io_uring_queue_exit(&io_uring.ring);
    }

    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

    pub fn submitAccept(
        io_uring: *IoUring,
        socket: socket_t,
        allocator: Allocator,
    ) !void {
        const sqe = c.io_uring_get_sqe(&io_uring.ring);

        const event = try allocator.create(Event);
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

    pub fn submitRead(
        io_uring: *IoUring,
        fd: fd_t,
        buf: []u8,
        allocator: Allocator,
    ) !void {
        const sqe = c.io_uring_get_sqe(&io_uring.ring);

        const event = try allocator.create(Event);
        event.* = Event{ .read = .{ .fd = fd, .buf = buf } };
        c.io_uring_sqe_set_data(sqe, event);

        c.io_uring_prep_read(sqe, fd, buf.ptr, @intCast(buf.len), 0);
        _ = c.io_uring_submit(&io_uring.ring);
    }

    pub fn submitWrite(
        io_uring: *IoUring,
        fd: fd_t,
        buf: []u8,
        allocator: Allocator,
    ) !void {
        const sqe = c.io_uring_get_sqe(&io_uring.ring);

        const event = try allocator.create(Event);
        event.* = Event{ .write = .{ .fd = fd, .buf = buf } };
        c.io_uring_sqe_set_data(sqe, event);

        c.io_uring_prep_write(sqe, fd, buf.ptr, @intCast(buf.len), 0);
        _ = c.io_uring_submit(&io_uring.ring);
    }

    pub fn submitClose(
        io_uring: *IoUring,
        fd: fd_t,
        allocator: Allocator,
    ) !void {
        const sqe = c.io_uring_get_sqe(&io_uring.ring);

        const event = try allocator.create(Event);
        event.* = Event{ .close = .{ .fd = fd } };
        c.io_uring_sqe_set_data(sqe, event);

        c.io_uring_prep_close(sqe, fd);
        _ = c.io_uring_submit(&io_uring.ring);
    }

    pub fn waitEvent(io_uring: *IoUring) !union(enum) {
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
