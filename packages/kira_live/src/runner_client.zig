//! Live-runner socket client. Extracted from runner_support.zig when the hot
//! reload listener made the connection multi-threaded: the sokol main thread
//! sends markers (log hooks, reload events) while the background reload
//! listener sends acks and staging results, so every write is serialized by a
//! mutex. READS stay single-threaded by protocol: the main thread reads only
//! until the initial bundle set is complete, then the reload listener becomes
//! the sole reader for the rest of the session.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const RunnerClient = struct {
    allocator: std.mem.Allocator,
    io_impl: std.Io.Threaded,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    reader_buffer: [4096]u8,
    writer_buffer: [4096]u8,
    write_mutex: std.atomic.Mutex = .unlocked,

    /// Heap-allocated so the client has a STABLE address: `reader`/`writer`
    /// hold pointers into this struct's own inline buffers, and `io_impl.io()`
    /// self-references `&self.io_impl`. Returning the struct by value copied
    /// those fields while their pointers still referenced the connect-local's
    /// (freed) stack — the writer then wrote through a dangling buffer pointer
    /// and crashed (EXC_BAD_ACCESS in sendText once the app started emitting
    /// log lines). Building in place fixes it.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !*RunnerClient {
        const self = try allocator.create(RunnerClient);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io_impl = .init(std.heap.smp_allocator, .{});
        self.write_mutex = .unlocked;
        const address = try std.Io.net.IpAddress.parse(host, port);
        self.stream = try std.Io.net.IpAddress.connect(&address, self.io_impl.io(), .{
            .mode = .stream,
            .protocol = .tcp,
        });
        self.reader = std.Io.net.Stream.Reader.init(self.stream, self.io_impl.io(), &self.reader_buffer);
        self.writer = std.Io.net.Stream.Writer.init(self.stream, self.io_impl.io(), &self.writer_buffer);
        return self;
    }

    pub fn close(self: *RunnerClient) void {
        self.stream.close(self.io_impl.io());
        self.io_impl.deinit();
        self.allocator.destroy(self);
    }

    pub fn sendText(self: *RunnerClient, kind: protocol.LiveMessageKind, text: []const u8) !void {
        while (!self.write_mutex.tryLock()) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        defer self.write_mutex.unlock();
        try protocol.writeFrame(&self.writer.interface, kind, text);
        try self.writer.interface.flush();
    }

    pub fn readFrame(self: *RunnerClient, allocator: std.mem.Allocator) !protocol.Frame {
        return protocol.readFrame(allocator, &self.reader.interface);
    }
};
