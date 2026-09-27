const std = @import("std");
const c = @import("c");

pub const Client = struct {
    ip: []const u8,
    port: u16,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    transport_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    heartbeat_thread: ?std.Thread = null,
    threaded_io: std.Io.Threaded,
    tls_client: ?*std.crypto.tls.Client = null,
    stream: ?std.Io.net.Stream = null,

    // Buffers for TLS and network I/O
    socket_write_buf: [4096]u8 = undefined,
    socket_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    stream_writer: ?std.Io.net.Stream.Writer = null,
    stream_reader: ?std.Io.net.Stream.Reader = null,

    pub fn init(allocator: std.mem.Allocator, ip: []const u8, port: u16) !*Client {
        const self = try allocator.create(Client);
        self.* = .{
            .ip = try allocator.dupe(u8, ip),
            .port = port,
            .allocator = allocator,
            .threaded_io = std.Io.Threaded.init(allocator, .{}),
        };
        return self;
    }

    pub fn startCast(self: *Client, stream_url: []const u8) !void {
        const io = self.threaded_io.io();

        // Parse IP address
        var ip_bytes: [4]u8 = undefined;
        var part_idx: usize = 0;
        var it = std.mem.splitScalar(u8, self.ip, '.');
        while (it.next()) |part| : (part_idx += 1) {
            if (part_idx >= 4) return error.InvalidIp;
            ip_bytes[part_idx] = try std.fmt.parseInt(u8, part, 10);
        }
        if (part_idx != 4) return error.InvalidIp;

        const ip_addr = std.Io.net.IpAddress{
            .ip4 = .{
                .bytes = ip_bytes,
                .port = self.port,
            },
        };

        c.blog(c.LOG_INFO, "zobscast connecting to Chromecast at %s:%u...", self.ip.ptr, self.port);
        const stream = try ip_addr.connect(io, .{ .mode = .stream });
        self.stream = stream;

        self.stream_writer = stream.writer(io, &self.tls_write_buf);
        self.stream_reader = stream.reader(io, &self.socket_read_buf);

        var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buffer);

        const tls_ptr = try self.allocator.create(std.crypto.tls.Client);
        tls_ptr.* = try std.crypto.tls.Client.init(
            &self.stream_reader.?.interface,
            &self.stream_writer.?.interface,
            .{
                .host = .no_verification,
                .ca = .no_verification,
                .entropy = &random_buffer,
                .read_buffer = &self.tls_read_buf,
                .write_buffer = &self.socket_write_buf,
                .realtime_now = std.Io.Timestamp.now(io, .real),
                .allow_truncation_attacks = true,
            },
        );
        self.tls_client = tls_ptr;
        self.running.store(true, .monotonic);

        c.blog(c.LOG_INFO, "zobscast TLS handshake with Chromecast established");

        // Step 1: Connect to receiver-0
        try self.sendMessage(
            "sender-0",
            "receiver-0",
            "urn:x-cast:com.google.cast.tp.connection",
            "{\"type\":\"CONNECT\"}",
        );

        // Step 2: Launch Default Media Receiver (appId: CC1AD845)
        try self.sendMessage(
            "sender-0",
            "receiver-0",
            "urn:x-cast:com.google.cast.receiver",
            "{\"type\":\"LAUNCH\",\"appId\":\"CC1AD845\",\"requestId\":1}",
        );

        // Step 3: Read responses until we find the transportId of the launched app
        try self.waitForTransportId();

        if (self.transport_id) |tid| {
            c.blog(c.LOG_INFO, "zobscast launched Media Receiver, transportId: %s", tid.ptr);

            // Step 4: Connect to the transportId
            try self.sendMessage(
                "sender-0",
                tid,
                "urn:x-cast:com.google.cast.tp.connection",
                "{\"type\":\"CONNECT\"}",
            );

            // Step 5: Send LOAD command with media URL
            var load_json_buf: [1024]u8 = undefined;
            const load_payload = try std.fmt.bufPrint(
                &load_json_buf,
                "{{" ++
                    "\"type\":\"LOAD\"," ++
                    "\"requestId\":2," ++
                    "\"media\":{{" ++
                    "\"contentId\":\"{s}\"," ++
                    "\"contentType\":\"video/mp4\"," ++
                    "\"streamType\":\"LIVE\"" ++
                    "}}," ++
                    "\"autoplay\":true" ++
                    "}}",
                .{stream_url},
            );

            try self.sendMessage(
                "sender-0",
                tid,
                "urn:x-cast:com.google.cast.media",
                load_payload,
            );
            c.blog(c.LOG_INFO, "zobscast sent media LOAD for URL: %s", stream_url.ptr);

            // Step 6: Start heartbeat thread
            self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeatLoop, .{self});
        } else {
            return error.NoTransportId;
        }
    }

    fn sendMessage(
        self: *Client,
        src: []const u8,
        dst: []const u8,
        ns: []const u8,
        payload: []const u8,
    ) !void {
        if (self.tls_client) |tls| {
            const raw_msg = try encodeCastMessage(self.allocator, src, dst, ns, payload);
            defer self.allocator.free(raw_msg);

            _ = try tls.writer.write(raw_msg);
        }
    }

    fn waitForTransportId(self: *Client) !void {
        var buf: [4096]u8 = undefined;

        var attempts: usize = 0;
        while (attempts < 20 and self.transport_id == null) : (attempts += 1) {
            if (self.tls_client) |tls| {
                // Read 4-byte header length
                var len_bytes: [4]u8 = undefined;
                try tls.reader.readSliceAll(&len_bytes);
                const msg_len = std.mem.readInt(u32, &len_bytes, .big);

                if (msg_len > 0 and msg_len < buf.len) {
                    try tls.reader.readSliceAll(buf[0..msg_len]);
                    self.extractTransportId(buf[0..msg_len]) catch {};
                }
            }
        }
    }

    fn extractTransportId(self: *Client, msg_bytes: []const u8) !void {
        // Find field 6: payload_utf8 (tag 0x32)
        var offset: usize = 0;
        while (offset < msg_bytes.len) {
            const tag_byte = msg_bytes[offset];
            offset += 1;
            const wire_type = tag_byte & 0x07;
            const field_num = tag_byte >> 3;

            if (wire_type == 0) { // varint
                while (offset < msg_bytes.len and (msg_bytes[offset] & 0x80) != 0) {
                    offset += 1;
                }
                offset += 1;
            } else if (wire_type == 2) { // length delimited
                var len: usize = 0;
                var shift: u6 = 0;
                while (offset < msg_bytes.len) {
                    const b = msg_bytes[offset];
                    offset += 1;
                    len |= @as(usize, b & 0x7f) << shift;
                    if ((b & 0x80) == 0) break;
                    shift += 7;
                }

                if (offset + len <= msg_bytes.len) {
                    if (field_num == 6) { // payload_utf8
                        const json_payload = msg_bytes[offset .. offset + len];
                        try self.parseJsonForTransportId(json_payload);
                    }
                    offset += len;
                }
            } else {
                break;
            }
        }
    }

    fn parseJsonForTransportId(self: *Client, json: []const u8) !void {
        // Fast search for "transportId":"..."
        const key = "\"transportId\":\"";
        if (std.mem.indexOf(u8, json, key)) |idx| {
            const start = idx + key.len;
            if (std.mem.indexOfScalar(u8, json[start..], '"')) |end_rel| {
                const tid = json[start .. start + end_rel];
                if (self.transport_id == null) {
                    self.transport_id = try self.allocator.dupe(u8, tid);
                }
            }
        }

        // Also search for "sessionId":"..."
        const s_key = "\"sessionId\":\"";
        if (std.mem.indexOf(u8, json, s_key)) |idx| {
            const start = idx + s_key.len;
            if (std.mem.indexOfScalar(u8, json[start..], '"')) |end_rel| {
                const sid = json[start .. start + end_rel];
                if (self.session_id == null) {
                    self.session_id = try self.allocator.dupe(u8, sid);
                }
            }
        }
    }

    fn heartbeatLoop(self: *Client) void {
        const io = self.threaded_io.io();
        while (self.running.load(.monotonic)) {
            io.sleep(std.Io.Duration.fromSeconds(5), .real) catch break;
            if (!self.running.load(.monotonic)) break;

            self.sendMessage(
                "sender-0",
                "receiver-0",
                "urn:x-cast:com.google.cast.tp.heartbeat",
                "{\"type\":\"PING\"}",
            ) catch break;
        }
    }

    pub fn stop(self: *Client) void {
        self.running.store(false, .monotonic);

        if (self.transport_id) |tid| {
            self.sendMessage(
                "sender-0",
                tid,
                "urn:x-cast:com.google.cast.media",
                "{\"type\":\"STOP\"}",
            ) catch {};
        }

        if (self.heartbeat_thread) |t| {
            t.join();
            self.heartbeat_thread = null;
        }

        if (self.tls_client) |tls| {
            self.allocator.destroy(tls);
            self.tls_client = null;
        }

        if (self.stream) |s| {
            s.close(self.threaded_io.io());
            self.stream = null;
        }
    }

    pub fn deinit(self: *Client) void {
        self.stop();
        if (self.transport_id) |tid| self.allocator.free(tid);
        if (self.session_id) |sid| self.allocator.free(sid);
        self.allocator.free(self.ip);
        self.threaded_io.deinit();
        self.allocator.destroy(self);
    }
};

fn encodeCastMessage(
    allocator: std.mem.Allocator,
    source_id: []const u8,
    destination_id: []const u8,
    namespace: []const u8,
    payload_utf8: []const u8,
) ![]u8 {
    var pb: std.ArrayListUnmanaged(u8) = .empty;
    defer pb.deinit(allocator);

    // Field 1: protocol_version = 0 (CASTV2_1_0)
    try pb.appendSlice(allocator, &[_]u8{ 0x08, 0x00 });

    // Field 2: source_id
    try writeStringField(&pb, allocator, 2, source_id);

    // Field 3: destination_id
    try writeStringField(&pb, allocator, 3, destination_id);

    // Field 4: namespace
    try writeStringField(&pb, allocator, 4, namespace);

    // Field 5: payload_type = 0 (STRING)
    try pb.appendSlice(allocator, &[_]u8{ 0x28, 0x00 });

    // Field 6: payload_utf8
    try writeStringField(&pb, allocator, 6, payload_utf8);

    // Prefix with 4-byte big-endian length
    const total_len: u32 = @intCast(pb.items.len);
    var result = try allocator.alloc(u8, 4 + pb.items.len);
    std.mem.writeInt(u32, result[0..4], total_len, .big);
    @memcpy(result[4..], pb.items);
    return result;
}

fn writeStringField(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    field_num: u32,
    str: []const u8,
) !void {
    const tag = (field_num << 3) | 2;
    try writeVarint(list, allocator, tag);
    try writeVarint(list, allocator, @intCast(str.len));
    try list.appendSlice(allocator, str);
}

fn writeVarint(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u32) !void {
    var v = val;
    while (v >= 0x80) {
        try list.append(allocator, @intCast((v & 0x7f) | 0x80));
        v >>= 7;
    }
    try list.append(allocator, @intCast(v));
}
