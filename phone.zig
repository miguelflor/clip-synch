const std = @import("std");

const Allocator = std.mem.Allocator;
const Stream = std.Io.net.Stream;

fn resolveHost(io: std.Io, name: []const u8, p: u16) !std.Io.net.IpAddress {
    var results_buffer: [16]std.Io.net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results_buffer);
    const host = try std.Io.net.HostName.init(name);
    try std.Io.net.HostName.lookup(host, io, &results, .{ .port = p });
    while (results.getOne(io)) |r| switch (r) {
        .address => |a| return a,
        .canonical_name => {},
    } else |err| switch (err) {
        error.Closed => return error.NoAddress,
        else => |e| return e,
    }
    return error.NoAddress;
}

fn readFrame(a: Allocator, io: std.Io, s: Stream) ![]u8 {
    var hdr: [4]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var r = s.reader(io, &rbuf);
    try r.interface.readSliceAll(&hdr);
    const len = std.mem.readInt(u32, &hdr, .big);
    if (len > (1 << 20)) return error.TooBig;
    const buf = try a.alloc(u8, len);
    errdefer a.free(buf);
    try r.interface.readSliceAll(buf);
    return buf;
}

fn termuxSet(io: std.Io, data: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{"termux-clipboard-set"},
        .stdin = .pipe,
    });
    var buf: [4096]u8 = undefined;
    var w = child.stdin.?.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);
}

fn termuxGet(a: Allocator, io: std.Io) ![]u8 {
    const res = try std.process.run(a, io, .{
        .argv = &.{"termux-clipboard-get"},
        .stdout_limit = .limited(1 << 20),
    });
    a.free(res.stderr);
    return res.stdout; // caller frees with a.free
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: {s} sub|push HOST PORT\n", .{args[0]});
        return error.Usage;
    }

    const port = try std.fmt.parseInt(u16, args[3], 10);
    const addr = try resolveHost(io, args[2], port);
    var s = try addr.connect(io, .{ .mode = .stream });
    defer s.close(io);

    if (std.mem.eql(u8, args[1], "sub")) {
        {
            var wbuf: [16]u8 = undefined;
            var w = s.writer(io, &wbuf);
            try w.interface.writeAll("S");
            try w.interface.flush();
        }
        while (true) { // blocks in the kernel, 0% CPU while idle
            const data = try readFrame(a, io, s);
            defer a.free(data);
            try termuxSet(io, data);
        }
    } else if (std.mem.eql(u8, args[1], "push")) {
        const data = try termuxGet(a, io);
        defer a.free(data);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(data.len), .big);
        var wbuf: [4096]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.writeAll("P");
        try w.interface.writeAll(&hdr);
        try w.interface.writeAll(data);
        try w.interface.flush();
    } else {
        return error.Usage;
    }
}
