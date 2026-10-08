const std = @import("std");

fn readFrame(a: std.mem.Allocator, s: std.net.Stream) ![]u8 {
    var hdr: [4]u8 = undefined;
    try s.readNoEof(&hdr);
    const len = std.mem.readInt(u32, &hdr, .big);
    if (len > (1 << 20)) return error.TooBig;
    const buf = try a.alloc(u8, len);
    try s.readNoEof(buf);
    return buf;
}

fn termuxSet(a: std.mem.Allocator, data: []const u8) !void {
    var ch = std.process.Child.init(&.{"termux-clipboard-set"}, a);
    ch.stdin_behavior = .Pipe;
    try ch.spawn();
    try ch.stdin.?.writeAll(data);
    ch.stdin.?.close();
    ch.stdin = null;
    _ = try ch.wait();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 4) return error.Usage; // phone sub|push HOST PORT

    const addr = try std.net.Address.parseIp(args[2], try std.fmt.parseInt(u16, args[3], 10));
    const s = try std.net.tcpConnectToAddress(addr);
    defer s.close();

    if (std.mem.eql(u8, args[1], "sub")) {
        try s.writeAll("S");
        while (true) { // blocks in the kernel, 0% CPU while idle
            const data = try readFrame(a, s);
            defer a.free(data);
            try termuxSet(a, data);
        }
    } else {
        var ch = std.process.Child.init(&.{"termux-clipboard-get"}, a);
        ch.stdout_behavior = .Pipe;
        try ch.spawn();
        const data = try ch.stdout.?.readToEndAlloc(a, 1 << 20);
        _ = try ch.wait();
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(data.len), .big);
        try s.writeAll("P");
        try s.writeAll(&hdr);
        try s.writeAll(data);
    }
}
