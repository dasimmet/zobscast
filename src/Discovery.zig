const std = @import("std");
const c = @import("c");

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
mutex: std.atomic.Mutex = .unlocked,

pub fn init(allocator: std.mem.Allocator) Discovery {
    return .{
        .allocator = allocator,
    };
}

pub fn scan(self: *Discovery, timeout_ms: c_int) !void {
    const sock = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
    if (c.is_socket_valid(sock) == 0) return error.SocketCreationFailed;
    defer _ = c.close(sock);

    var reuse: c_int = 1;
    _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

    var bind_addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    bind_addr.sin_family = c.AF_INET;
    bind_addr.sin_port = 0; // ephemeral port for sending query
    c.set_inaddr_any(&bind_addr);

    if (c.bind(sock, @ptrCast(&bind_addr), @sizeOf(c.sockaddr_in)) < 0) {
        return error.BindFailed;
    }

    // Target mDNS multicast address 224.0.0.251:5353
    var mdns_addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    mdns_addr.sin_family = c.AF_INET;
    mdns_addr.sin_port = c.htons(5353);
    _ = c.inet_pton(c.AF_INET, "224.0.0.251", &mdns_addr.sin_addr);

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

    _ = c.sendto(
        sock,
        &query_data,
        query_data.len,

        0,
        @ptrCast(&mdns_addr),
        @sizeOf(c.sockaddr_in),
    );

    // Receive responses with timeout
    const start_time = getMilliTime();
    var recv_buf: [4096]u8 = undefined;

    while (true) {
        const elapsed = getMilliTime() - start_time;
        const remaining = timeout_ms - @as(c_int, @intCast(@max(0, elapsed)));
        if (remaining <= 0) break;

        var pfd = [_]c.pollfd{.{
            .fd = sock,
            .events = c.POLLIN,
            .revents = 0,
        }};
        const poll_res = c.poll(&pfd, 1, remaining);
        if (poll_res <= 0) break;

        var src_addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        var src_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        const n = c.recvfrom(sock, &recv_buf, recv_buf.len, 0, @ptrCast(&src_addr), &src_len);
        if (n <= 0) continue;

        var ip_str_buf: [c.INET_ADDRSTRLEN]u8 = undefined;
        if (c.inet_ntop(c.AF_INET, &src_addr.sin_addr, &ip_str_buf, c.INET_ADDRSTRLEN) == null) continue;
        const ip_len = std.mem.indexOfScalar(u8, &ip_str_buf, 0) orelse ip_str_buf.len;
        const sender_ip = ip_str_buf[0..ip_len];

        self.parseMdnsPacket(recv_buf[0..@intCast(n)], sender_ip) catch {};
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
    while (!self.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer self.mutex.unlock();

    // Check if device with same IP already exists
    for (self.devices.items) |existing| {
        if (std.mem.eql(u8, existing.ip, dev.ip)) {
            return;
        }
    }

    const owned_dev = try dev.clone(self.allocator);
    try self.devices.append(self.allocator, owned_dev);
    c.blog(c.LOG_INFO, "zobscast discovered device: %.*s (%.*s:%u)", @as(c_int, @intCast(owned_dev.name.len)), owned_dev.name.ptr, @as(c_int, @intCast(owned_dev.ip.len)), owned_dev.ip.ptr, owned_dev.port);
}

pub fn getDevices(self: *Discovery, allocator: std.mem.Allocator, out: *std.ArrayList(Device)) !void {
    while (!self.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer self.mutex.unlock();

    for (self.devices.items) |d| {
        const dev_clone = try d.clone(allocator);
        try out.append(allocator, dev_clone);
    }
}

pub fn deinit(self: *Discovery) void {
    while (!self.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    for (self.devices.items) |d| {
        d.deinit(self.allocator);
    }
    self.devices.deinit(self.allocator);
    self.mutex.unlock();
}

fn getMilliTime() i64 {
    return @intCast(@divTrunc(c.os_gettime_ns(), 1_000_000));
}
