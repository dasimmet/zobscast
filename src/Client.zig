const std = @import("std");
const builtin = @import("builtin");

pub const Client = @This();

max_attempts: usize = 30,
ip: []const u8,
port: u16,
allocator: std.mem.Allocator,
io: std.Io,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
transport_id: ?[]const u8 = null,
session_id: ?[]const u8 = null,
heartbeat_thread: ?std.Thread = null,
tls_client: ?*std.crypto.tls.Client = null,
stream: ?std.Io.net.Stream = null,

// Buffers for TLS and network I/O
socket_write_buf: [4096]u8 = undefined,
socket_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
stream_writer: ?std.Io.net.Stream.Writer = null,
stream_reader: ?std.Io.net.Stream.Reader = null,

pub fn init(allocator: std.mem.Allocator, ip: []const u8, port: u16, io: std.Io) !*Client {
    const self = try allocator.create(Client);
    self.* = .{
        .ip = try allocator.dupe(u8, ip),
        .port = port,
        .allocator = allocator,
        .io = io,
    };
    return self;
}

pub fn startCast(self: *Client, stream_url: []const u8) !void {
    // Parse IP address
    var ip_bytes: [4]u8 = undefined;
    var part_idx: usize = 0;
    var it = std.mem.splitScalar(u8, self.ip, '.');
    while (it.next()) |part| : (part_idx += 1) {
        if (part_idx >= 4) {
            std.log.err("zobscast Client: IP has more than 4 octets: {s}", .{self.ip});
            return error.InvalidIp;
        }
        ip_bytes[part_idx] = std.fmt.parseInt(u8, part, 10) catch |err| {
            std.log.err("zobscast Client: invalid IP octet '{s}' in '{s}': {}", .{ part, self.ip, err });
            return error.InvalidIp;
        };
    }
    if (part_idx != 4) {
        std.log.err("zobscast Client: IP has {d} octets (expected 4): {s}", .{ part_idx, self.ip });
        return error.InvalidIp;
    }

    const ip_addr = std.Io.net.IpAddress{
        .ip4 = .{
            .bytes = ip_bytes,
            .port = self.port,
        },
    };

    std.log.info("zobscast Client: connecting to Chromecast at {d}.{d}.{d}.{d}:{d}...", .{
        ip_bytes[0],
        ip_bytes[1],
        ip_bytes[2],
        ip_bytes[3],
        self.port,
    });

    const stream = ip_addr.connect(self.io, .{ .mode = .stream }) catch |err| {
        std.log.err("zobscast Client: failed to connect to {s}:{d}: {}", .{
            self.ip,
            self.port,
            err,
        });
        return err;
    };
    self.stream = stream;

    if (comptime builtin.os.tag != .windows) {
        const tv: std.posix.timeval = .{ .sec = 8, .usec = 0 };
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};
    }

    self.stream_writer = stream.writer(self.io, &self.tls_write_buf);
    self.stream_reader = stream.reader(self.io, &self.socket_read_buf);

    var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    self.io.random(&random_buffer);

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
            .realtime_now = std.Io.Timestamp.now(self.io, .real),
            .allow_truncation_attacks = true,
        },
    );
    self.tls_client = tls_ptr;
    self.running.store(true, .monotonic);

    std.log.info("zobscast TLS handshake with Chromecast established", .{});

    // Step 1: Connect to receiver-0
    try self.sendJsonMessage(
        "sender-0",
        "receiver-0",
        "urn:x-cast:com.google.cast.tp.connection",
        Message.Connect,
    );

    // Step 2: Launch Default Media Receiver (appId: CC1AD845)
    try self.sendJsonMessage(
        "sender-0",
        "receiver-0",
        "urn:x-cast:com.google.cast.receiver",
        Message.Launch{
            .requestId = 1,
        },
    );

    // Step 3: Read responses until we find the transportId of the launched app
    try self.waitForTransportId();

    if (self.transport_id) |tid| {
        std.log.info("zobscast launched Media Receiver, transportId: {s}", .{tid});
        // Step 4: Connect to the transportId
        try self.sendJsonMessage(
            "sender-0",
            tid,
            "urn:x-cast:com.google.cast.tp.connection",
            Message.Connect,
        );

        // Step 5: Send LOAD command with media URL
        try self.sendJsonMessage(
            "sender-0",
            tid,
            "urn:x-cast:com.google.cast.media",
            Message.Load{
                .requestId = 2,
                .media = .{
                    .contentId = stream_url,
                    .contentType = "video/mp4",
                    .streamType = "LIVE",
                },
                .autoplay = true,
            },
        );
        std.log.info("zobscast sent media LOAD for URL: {s}", .{stream_url});

        // Step 6: Start heartbeat thread
        self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeatLoop, .{self});
    } else {
        return error.NoTransportId;
    }
}

pub const Message = struct {
    type: []const u8,
    pub const Connect: Message = .{
        .type = "CONNECT",
    };
    pub const Stop: Message = .{
        .type = "STOP",
    };

    pub const Launch = struct {
        type: []const u8 = "LAUNCH",
        appId: []const u8 = "CC1AD845",
        requestId: u32,
    };

    pub const Load = struct {
        type: []const u8 = "LOAD",
        requestId: u32,
        media: MediaInfo,
        autoplay: bool = true,

        pub const MediaInfo = struct {
            contentId: []const u8,
            contentType: []const u8 = "video/mp4",
            streamType: []const u8 = "LIVE",
        };
    };

    pub const Heartbeat = struct {
        type: []const u8,

        pub const PING: Heartbeat = .{
            .type = "PING",
        };
        pub const PONG: Heartbeat = .{
            .type = "PONG",
        };
    };

    pub const ReceiverResponse = struct {
        requestId: ?i64 = null,
        status: ?ReceiverStatus = null,

        pub const ReceiverStatus = struct {
            applications: ?[]const Application = null,

            pub const Application = struct {
                appId: ?[]const u8 = null,
                sessionId: ?[]const u8 = null,
                transportId: ?[]const u8 = null,
            };
        };
    };
};

fn sendJsonMessage(
    self: *Client,
    src: []const u8,
    dst: []const u8,
    ns: []const u8,
    val: anytype,
) !void {
    const json_str = try std.json.Stringify.valueAlloc(self.allocator, val, .{
        .emit_null_optional_fields = false,
    });
    defer self.allocator.free(json_str);
    try self.sendMessage(src, dst, ns, json_str);
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

        std.log.info("zobscast CastV2 tx: ns='{s}' payload='{s}'", .{
            ns,
            payload[0..@min(payload.len, 200)],
        });
        _ = try tls.writer.write(raw_msg);
        try tls.writer.flush();
        if (self.stream_writer) |*sw| {
            try sw.interface.flush();
        }
    }
}

fn waitForTransportId(self: *Client) !void {
    var buf: [8192]u8 = undefined;

    std.log.info("zobscast CastV2: waiting for receiver response...", .{});
    var attempts: usize = 0;
    while (attempts < self.max_attempts and self.transport_id == null) : (attempts += 1) {
        if (self.tls_client) |tls| {
            // Read 4-byte big-endian message length
            var len_bytes: [4]u8 = undefined;
            try tls.reader.readSliceAll(&len_bytes);
            const msg_len = std.mem.readInt(u32, &len_bytes, .big);

            if (msg_len == 0 or msg_len >= buf.len) continue;
            try tls.reader.readSliceAll(buf[0..msg_len]);
            const msg = buf[0..msg_len];

            // CastMessage proto: field 4 = namespace, field 6 = payload_utf8
            const ns = extractPbString(msg, 4) orelse "";
            const payload = extractPbString(msg, 6) orelse "";

            std.log.info("zobscast CastV2 rx [{}]: ns='{s}' payload='{s}'", .{
                attempts,
                ns,
                payload[0..@min(payload.len, 200)],
            });

            if (std.mem.eql(u8, ns, "urn:x-cast:com.google.cast.tp.heartbeat")) {
                const parsed = std.json.parseFromSlice(
                    Message.Heartbeat,
                    self.allocator,
                    payload,
                    .{ .ignore_unknown_fields = true },
                ) catch null;
                if (parsed) |p| {
                    defer p.deinit();
                    if (std.mem.eql(u8, p.value.type, "PING")) {
                        // Reply with PONG to keep the connection alive
                        std.log.info("zobscast CastV2: replying PONG", .{});
                        self.sendJsonMessage(
                            "sender-0",
                            "receiver-0",
                            "urn:x-cast:com.google.cast.tp.heartbeat",
                            Message.Heartbeat.PONG,
                        ) catch {};
                    }
                }
            } else {
                self.extractTransportId(msg) catch {};
            }
        }
    }

    if (self.transport_id == null) {
        std.log.err("zobscast CastV2: no transportId found after {d} messages", .{self.max_attempts});
    }
}

/// Extract a length-delimited string field (wire type 2) from a raw protobuf
/// message by field number. Returns a slice into `msg` (no allocation needed).
fn extractPbString(msg: []const u8, target_field: u32) ?[]const u8 {
    var off: usize = 0;
    while (off < msg.len) {
        // Read tag varint
        var tag: u32 = 0;
        var shift: u5 = 0;
        while (off < msg.len) {
            const b = msg[off];
            off += 1;
            tag |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
        }
        const wire_type = tag & 0x07;
        const field_num = tag >> 3;

        switch (wire_type) {
            0 => { // varint — skip
                while (off < msg.len) {
                    const b = msg[off];
                    off += 1;
                    if ((b & 0x80) == 0) break;
                }
            },
            2 => { // length-delimited
                var len: usize = 0;
                var lshift: u6 = 0;
                while (off < msg.len) {
                    const b = msg[off];
                    off += 1;
                    len |= @as(usize, b & 0x7f) << lshift;
                    if ((b & 0x80) == 0) break;
                    lshift += 7;
                }
                if (off + len > msg.len) return null;
                if (field_num == target_field) return msg[off .. off + len];
                off += len;
            },
            5 => off += 4, // 32-bit fixed
            1 => off += 8, // 64-bit fixed
            else => return null,
        }
    }
    return null;
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

fn parseJsonForTransportId(self: *Client, json_bytes: []const u8) !void {
    const parsed = std.json.parseFromSlice(Message.ReceiverResponse, self.allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        try self.parseJsonForTransportIdFallback(json_bytes);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.status) |st| {
        if (st.applications) |apps| {
            for (apps) |app| {
                if (self.transport_id == null and app.transportId != null) {
                    self.transport_id = try self.allocator.dupe(u8, app.transportId.?);
                }
                if (self.session_id == null and app.sessionId != null) {
                    self.session_id = try self.allocator.dupe(u8, app.sessionId.?);
                }
            }
        }
    }

    if (self.transport_id == null) {
        try self.parseJsonForTransportIdFallback(json_bytes);
    }
}

fn parseJsonForTransportIdFallback(self: *Client, json_bytes: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_bytes, .{}) catch return;
    defer parsed.deinit();
    self.extractIdsFromValue(parsed.value);
}

fn extractIdsFromValue(self: *Client, val: std.json.Value) void {
    switch (val) {
        .object => |obj| {
            if (self.transport_id == null) {
                if (obj.get("transportId")) |tid_val| {
                    if (tid_val == .string) {
                        self.transport_id = self.allocator.dupe(u8, tid_val.string) catch null;
                    }
                }
            }
            if (self.session_id == null) {
                if (obj.get("sessionId")) |sid_val| {
                    if (sid_val == .string) {
                        self.session_id = self.allocator.dupe(u8, sid_val.string) catch null;
                    }
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                self.extractIdsFromValue(entry.value_ptr.*);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                self.extractIdsFromValue(item);
            }
        },
        else => {},
    }
}

fn heartbeatLoop(self: *Client) void {
    while (self.running.load(.monotonic)) {
        self.io.sleep(std.Io.Duration.fromSeconds(5), .real) catch break;
        if (!self.running.load(.monotonic)) break;

        self.sendJsonMessage(
            "sender-0",
            "receiver-0",
            "urn:x-cast:com.google.cast.tp.heartbeat",
            Message.Heartbeat.PING,
        ) catch break;
    }
}

pub fn stop(self: *Client) void {
    self.running.store(false, .monotonic);

    if (self.transport_id) |tid| {
        self.sendJsonMessage(
            "sender-0",
            tid,
            "urn:x-cast:com.google.cast.media",
            Message.Stop,
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
        s.close(self.io);
        self.stream = null;
    }
}

pub fn deinit(self: *Client) void {
    self.stop();
    if (self.transport_id) |tid| self.allocator.free(tid);
    if (self.session_id) |sid| self.allocator.free(sid);
    self.allocator.free(self.ip);
    self.allocator.destroy(self);
}

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
