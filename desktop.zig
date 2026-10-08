const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/Xfixes.h");
});

const Allocator = std.mem.Allocator;
const Stream = std.Io.net.Stream;

fn getClip(a: Allocator, io: std.Io) ![]u8 {
    const result = try std.process.run(a, io, .{
        .argv = &.{ "xclip", "-o", "-selection", "clipboard" },
        .stdout_limit = .limited(1 << 20),
    });
    a.free(result.stderr);
    return result.stdout; // caller frees with a.free
}

fn setClip(io: std.Io, data: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "xclip", "-i", "-selection", "clipboard" },
        .stdin = .pipe,
    });
    var buf: [4096]u8 = undefined;
    var w = child.stdin.?.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io); // xclip forks into background to own the selection
}

fn sendFrame(io: std.Io, s: Stream, data: []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(data.len), .big);
    var buf: [4096]u8 = undefined;
    var w = s.writer(io, &buf);
    try w.interface.writeAll(&hdr);
    try w.interface.writeAll(data);
    try w.interface.flush();
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

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;

    // CLI: desktop <our-ip> <phone-ip>  — bind to our-ip, allow only phone-ip.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: {s} <our-ip> <phone-ip>\n", .{args[0]});
        return error.Usage;
    }
    const addr = try std.Io.net.IpAddress.parse(args[1], 7777);
    const allowed_ip4_bytes: [4]u8 = blk: {
        const parsed = try std.Io.net.IpAddress.parse(args[2], 0);
        break :blk switch (parsed) {
            .ip4 => |ip| ip.bytes,
            .ip6 => return error.OnlyIpv4Supported,
        };
    };

    // ignore SIGPIPE so writes to dead subscribers return errors instead
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);

    // --- X11 / XFixes ---
    const dpy = c.XOpenDisplay(null) orelse return error.NoDisplay;
    const root = c.XDefaultRootWindow(dpy);
    const clip_atom = c.XInternAtom(dpy, "CLIPBOARD", 0);
    var ev_base: c_int = 0;
    var err_base: c_int = 0;
    if (c.XFixesQueryExtension(dpy, &ev_base, &err_base) == 0) return error.NoXFixes;
    c.XFixesSelectSelectionInput(dpy, root, clip_atom, c.XFixesSetSelectionOwnerNotifyMask);
    const xfd = c.XConnectionNumber(dpy);

    // --- network: bind to our IP (from CLI arg 1) ---
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var subs: std.ArrayList(Stream) = .empty;
    defer subs.deinit(a);
    var last: []u8 = try a.dupe(u8, "");

    while (true) {
        // drain events Xlib may have already buffered (poll wouldn't see them)
        while (c.XPending(dpy) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(dpy, &ev);
            if (ev.type != ev_base + c.XFixesSelectionNotify) continue;

            const cur = getClip(a, io) catch continue;
            if (std.mem.eql(u8, cur, last)) { a.free(cur); continue; }
            a.free(last);
            last = cur;

            var i: usize = 0;
            while (i < subs.items.len) {
                sendFrame(io, subs.items[i], last) catch {
                    subs.items[i].close(io);
                    _ = subs.swapRemove(i);
                    continue;
                };
                i += 1;
            }
        }

        // sleep until X or a new TCP connection has something for us
        var fds = [_]posix.pollfd{
            .{ .fd = xfd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = server.socket.handle, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, -1);

        if (fds[1].revents & posix.POLL.IN != 0) {
            const stream = try server.accept(io);
            // ACL: reject any peer whose IPv4 address != allowed phone.
            {
                const allowed = switch (stream.socket.address) {
                    .ip4 => |ip| std.mem.eql(u8, &ip.bytes, &allowed_ip4_bytes),
                    .ip6 => false,
                };
                if (!allowed) {
                    stream.close(io);
                    continue;
                }
            }
            var kind: [1]u8 = undefined;
            {
                var kbuf: [16]u8 = undefined;
                var kr = stream.reader(io, &kbuf);
                kr.interface.readSliceAll(&kind) catch {
                    stream.close(io);
                    continue;
                };
            }
            switch (kind[0]) {
                'S' => try subs.append(a, stream),
                'P' => {
                    defer stream.close(io);
                    const data = readFrame(a, io, stream) catch continue;
                    a.free(last);
                    last = data;            // set BEFORE xclip so the echo is ignored
                    setClip(io, data) catch {};
                },
                else => stream.close(io),
            }
        }
    }
}
