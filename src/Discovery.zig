const std = @import("std");

pub const Device = struct {
    name: []const u8,
    ip: []const u8,
    port: u16,
    model: []const u8,

    pub fn clone(self: Device, allocator: std.mem.Allocator) !Device {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .ip = try allocator.dupe(u8, self.ip),
            .port = self.port,
            .model = try allocator.dupe(u8, self.model),
        };
    }

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.ip);
        allocator.free(self.model);
    }
};

pub const Discovery = @This();
devices: std.ArrayListUnmanaged(Device) = .empty,
allocator: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator, io: std.Io) Discovery {
    return .{
        .allocator = allocator,
        .io = io,
    };
}

pub fn scan(self: *Discovery, timeout_ms: i64) !void {
    if (timeout_ms <= 0) return;

    const io = self.io;
    const bind_addr: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
    const socket = try bind_addr.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    // Target mDNS multicast address 224.0.0.251:5353
    const mdns_addr = try std.Io.net.IpAddress.parse("224.0.0.251", 5353);

    // Build standard mDNS query for _googlecast._tcp.local (PTR)
    const query_data = [_]u8{
        0x00, 0x00, // ID
        0x00, 0x00, // Flags
        0x00, 0x01, // Questions: 1
        0x00, 0x00, // Answer RRs: 0
        0x00, 0x00, // Authority RRs: 0
        0x00, 0x00, // Additional RRs: 0
        // \x0b_googlecast\x04_tcp\x05local\x00
        11,   '_',
        'g',  'o',
        'o',  'g',
        'l',  'e',
        'c',  'a',
        's',  't',
        4,    '_',
        't',  'c',
        'p',  5,
        'l',  'o',
        'c',  'a',
        'l',  0,
        0x00, 0x0c, // QType: PTR = 12
        0x00, 0x01, // QClass: IN = 1
    };

    socket.send(io, &mdns_addr, &query_data) catch {};

    // Receive responses with timeout
    const deadline = std.Io.Timestamp.now(io, .awake)
        .addDuration(std.Io.Duration.fromMilliseconds(timeout_ms))
        .withClock(.awake);
    var recv_buf: [4096]u8 = undefined;

    while (true) {
        const message = socket.receiveTimeout(io, &recv_buf, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };

        var sender_ip_buf: [16]u8 = undefined;
        const sender_ip = switch (message.from) {
            .ip4 => |address| try std.fmt.bufPrint(&sender_ip_buf, "{d}.{d}.{d}.{d}", .{
                address.bytes[0],
                address.bytes[1],
                address.bytes[2],
                address.bytes[3],
            }),
            .ip6 => continue,
        };
        self.parseMdnsPacket(message.data, sender_ip) catch {};
    }
}

fn parseMdnsPacket(self: *Discovery, packet: []const u8, sender_ip: []const u8) !void {
    if (packet.len < 12) return;

    const qd_count = std.mem.readInt(u16, packet[4..][0..2], .big);
    const an_count = std.mem.readInt(u16, packet[6..][0..2], .big);
    const ar_count = std.mem.readInt(u16, packet[10..][0..2], .big);

    var offset: usize = 12;

    // Skip questions
    var q: usize = 0;
    while (q < qd_count and offset < packet.len) : (q += 1) {
        offset = skipDnsName(packet, offset);
        offset += 4; // QType + QClass
    }

    var friendly_name: ?[]const u8 = null;
    var model_name: ?[]const u8 = null;
    var device_ip: ?[]const u8 = null;
    var port: u16 = 8009;

    var ip_buf: [16]u8 = undefined;

    // Parse Answer & Additional records
    const total_records = @as(usize, an_count) + ar_count;
    var r: usize = 0;
    while (r < total_records and offset < packet.len) : (r += 1) {
        offset = skipDnsName(packet, offset);
        if (offset + 10 > packet.len) break;

        const rtype = std.mem.readInt(u16, packet[offset..][0..2], .big);
        // offset + 2: rclass
        // offset + 4: ttl (4 bytes)
        const rdlength = std.mem.readInt(u16, packet[offset + 8 ..][0..2], .big);

        offset += 10;

        if (offset + rdlength > packet.len) break;
        const rdata = packet[offset .. offset + rdlength];

        switch (rtype) {
            1 => { // A record (IPv4 address)
                if (rdlength == 4) {
                    const formatted = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
                        rdata[0], rdata[1], rdata[2], rdata[3],
                    }) catch null;
                    if (formatted) |ip| {
                        device_ip = ip;
                    }
                }
            },
            16 => { // TXT record
                var txt_off: usize = 0;
                while (txt_off < rdata.len) {
                    const txt_len = rdata[txt_off];
                    txt_off += 1;
                    if (txt_off + txt_len > rdata.len) break;
                    const entry = rdata[txt_off .. txt_off + txt_len];
                    txt_off += txt_len;

                    if (std.mem.startsWith(u8, entry, "fn=")) {
                        friendly_name = entry[3..];
                    } else if (std.mem.startsWith(u8, entry, "md=")) {
                        model_name = entry[3..];
                    }
                }
            },
            33 => { // SRV record
                if (rdlength >= 6) {
                    port = std.mem.readInt(u16, rdata[4..][0..2], .big);
                }
            },

            else => {},
        }

        offset += rdlength;
    }

    const effective_ip = device_ip orelse sender_ip;
    const effective_name = friendly_name orelse model_name orelse effective_ip;
    const effective_model = model_name orelse "Chromecast";

    self.addDevice(.{
        .name = effective_name,
        .ip = effective_ip,
        .port = port,
        .model = effective_model,
    }) catch {};
}

fn skipDnsName(packet: []const u8, start_offset: usize) usize {
    var offset = start_offset;
    while (offset < packet.len) {
        const len = packet[offset];
        if (len == 0) {
            return offset + 1;
        }
        if ((len & 0xc0) == 0xc0) {
            return offset + 2; // compressed pointer
        }
        offset += 1 + len;
    }
    return offset;
}

fn addDevice(self: *Discovery, dev: Device) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // Check if device with same IP already exists
    for (self.devices.items) |existing| {
        if (std.mem.eql(u8, existing.ip, dev.ip)) {
            return;
        }
    }

    const owned_dev = try dev.clone(self.allocator);
    try self.devices.append(self.allocator, owned_dev);
    std.log.info("zobscast discovered device: {s} ({s}:{d})", .{
        owned_dev.name,
        owned_dev.ip,
        owned_dev.port,
    });
}

pub fn getDevices(self: *Discovery, allocator: std.mem.Allocator, out: *std.ArrayList(Device)) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    for (self.devices.items) |d| {
        const dev_clone = try d.clone(allocator);
        try out.append(allocator, dev_clone);
    }
}

pub fn deinit(self: *Discovery) void {
    self.mutex.lockUncancelable(self.io);
    for (self.devices.items) |d| {
        d.deinit(self.allocator);
    }
    self.devices.deinit(self.allocator);
    self.mutex.unlock(self.io);
}
