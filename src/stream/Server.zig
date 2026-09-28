const std = @import("std");
const c = @import("c");
const Output = @import("../Output.zig");
const Device = @import("../cast/Discovery.zig").Device;

const settings_html = @embedFile("../web/index.html");
const settings_css = @embedFile("../web/style.css");
const settings_js = @embedFile("../web/app.js");

pub const Server = struct {
    server_fd: c.SOCKET = c.INVALID_SOCKET_VALUE,
    port: u16 = 0,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    clients: std.ArrayListUnmanaged(c.SOCKET) = .empty,
    client_mutex: std.atomic.Mutex = .unlocked,
    thread: ?std.Thread = null,
    allocator: std.mem.Allocator,
    header_data: std.ArrayListUnmanaged(u8) = .empty,
    header_mutex: std.atomic.Mutex = .unlocked,
    output: ?*Output = null,

    pub fn init(allocator: std.mem.Allocator, output: ?*Output) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
            .output = output,
        };
        return self;
    }

    pub fn start(self: *Server, preferred_port: u16) !u16 {
        if (self.running.load(.monotonic)) {
            return self.port;
        }

        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (c.is_socket_valid(fd) == 0) return error.SocketCreationFailed;

        var opt: c_int = 1;
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, @ptrCast(&opt), @sizeOf(c_int));

        var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        addr.sin_family = c.AF_INET;
        c.set_inaddr_any(&addr);

        addr.sin_port = c.htons(preferred_port);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) < 0) {
            addr.sin_port = 0;
            if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) < 0) {
                _ = c.close(fd);
                return error.BindFailed;
            }
        }

        if (c.listen(fd, 10) < 0) {
            _ = c.close(fd);
            return error.ListenFailed;
        }

        var actual_addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        var addr_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        if (c.getsockname(fd, @ptrCast(&actual_addr), &addr_len) == 0) {
            self.port = std.mem.bigToNative(u16, actual_addr.sin_port);
        } else {
            self.port = preferred_port;
        }

        self.server_fd = fd;
        self.running.store(true, .monotonic);

        self.thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch |err| {
            _ = c.close(fd);
            self.server_fd = c.INVALID_SOCKET_VALUE;
            return err;
        };

        c.blog(c.LOG_INFO, "zobscast HTTP streaming server listening on port %u", self.port);
        return self.port;
    }

    pub fn setHeader(self: *Server, header: []const u8) void {
        while (!self.header_mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.header_mutex.unlock();
        self.header_data.clearRetainingCapacity();
        self.header_data.appendSlice(self.allocator, header) catch {};
    }

    pub fn broadcast(self: *Server, data: []const u8) void {
        while (!self.client_mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.client_mutex.unlock();

        var i: usize = 0;
        while (i < self.clients.items.len) {
            const client_fd = self.clients.items[i];
            const res = c.send(client_fd, data.ptr, @intCast(data.len), c.MSG_NOSIGNAL);
            if (res < 0) {
                _ = c.close(client_fd);
                _ = self.clients.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clearClients(self: *Server) void {
        while (!self.client_mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.client_mutex.unlock();

        for (self.clients.items) |cfd| {
            _ = c.close(cfd);
        }
        self.clients.clearRetainingCapacity();
    }

    fn acceptLoop(self: *Server) void {
        while (self.running.load(.monotonic)) {
            var fds = [_]c.pollfd{.{
                .fd = self.server_fd,
                .events = c.POLLIN,
                .revents = 0,
            }};
            const poll_res = c.poll(&fds, 1, 200);
            if (poll_res <= 0) continue;

            var client_addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
            var client_len: c.socklen_t = @sizeOf(c.sockaddr_in);
            const client_fd = c.accept(self.server_fd, @ptrCast(&client_addr), &client_len);
            if (c.is_socket_valid(client_fd) == 0) continue;

            var nodelay: c_int = 1;
            _ = c.setsockopt(client_fd, c.IPPROTO_TCP, c.TCP_NODELAY, @ptrCast(&nodelay), @sizeOf(c_int));
            var sndbuf: c_int = 128 * 1024;
            _ = c.setsockopt(client_fd, c.SOL_SOCKET, c.SO_SNDBUF, @ptrCast(&sndbuf), @sizeOf(c_int));

            _ = std.Thread.spawn(.{}, handleClient, .{ self, client_fd }) catch {
                _ = c.close(client_fd);
            };
        }
    }

    fn handleClient(self: *Server, client_fd: c.SOCKET) void {
        var req_buf: [4096]u8 = undefined;
        const n = c.recv(client_fd, &req_buf, req_buf.len, 0);
        if (n <= 0) {
            _ = c.close(client_fd);
            return;
        }

        const req_slice = req_buf[0..@intCast(n)];
        const first_line_end = std.mem.indexOf(u8, req_slice, "\r\n") orelse req_slice.len;
        const first_line = req_slice[0..first_line_end];

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse "";
        const path = parts.next() orelse "";

        c.blog(c.LOG_INFO, "zobscast HTTP: %.*s %.*s", @as(c_int, @intCast(method.len)), method.ptr, @as(c_int, @intCast(path.len)), path.ptr);

        // CORS preflight
        if (std.mem.eql(u8, method, "OPTIONS")) {
            const cors_hdr =
                "HTTP/1.1 204 No Content\r\n" ++
                "Access-Control-Allow-Origin: *\r\n" ++
                "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
                "Access-Control-Allow-Headers: Content-Type\r\n" ++
                "Connection: close\r\n\r\n";
            _ = c.send(client_fd, cors_hdr.ptr, @intCast(cors_hdr.len), 0);
            _ = c.close(client_fd);
            return;
        }

        // Live stream route
        if (std.mem.startsWith(u8, path, "/live.mp4")) {
            const http_response_header =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: video/mp4\r\n" ++
                "Access-Control-Allow-Origin: *\r\n" ++
                "Cache-Control: no-cache, no-store\r\n" ++
                "Connection: close\r\n" ++
                "\r\n";

            _ = c.send(client_fd, http_response_header.ptr, @intCast(http_response_header.len), 0);

            // Send initialization header (ftyp + moov) if available
            {
                while (!self.header_mutex.tryLock()) {
                    std.Thread.yield() catch {};
                }
                if (self.header_data.items.len > 0) {
                    _ = c.send(client_fd, self.header_data.items.ptr, @intCast(self.header_data.items.len), 0);
                    c.blog(c.LOG_INFO, "zobscast HTTP: client connected, sent init header (%u bytes)", @as(c_uint, @intCast(self.header_data.items.len)));
                } else {
                    c.blog(c.LOG_WARNING, "zobscast HTTP: client connected before init header was ready");
                }
                self.header_mutex.unlock();
            }

            // Register client to receive subsequent fragments
            {
                while (!self.client_mutex.tryLock()) {
                    std.Thread.yield() catch {};
                }
                self.clients.append(self.allocator, client_fd) catch {
                    _ = c.close(client_fd);
                };
                self.client_mutex.unlock();
            }
            return;
        }

        // Web Settings UI
        if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/settings"))) {
            self.sendStaticResponse(client_fd, "text/html; charset=utf-8", settings_html);
            return;
        }

        // Web Settings CSS
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/style.css")) {
            self.sendStaticResponse(client_fd, "text/css; charset=utf-8", settings_css);
            return;
        }

        // Web Settings JS
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/app.js")) {
            self.sendStaticResponse(client_fd, "application/javascript; charset=utf-8", settings_js);
            return;
        }

        // API: Get current settings
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/settings")) {
            self.handleGetSettings(client_fd);
            return;
        }

        // API: Get discovered devices
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/devices")) {
            self.handleGetDevices(client_fd);
            return;
        }

        // API: Trigger device scan
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/scan")) {
            self.handleScan(client_fd);
            return;
        }

        // API: Update settings
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/settings")) {
            self.handleUpdateSettings(client_fd, req_slice);
            return;
        }

        // API: Toggle cast stream
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/toggle")) {
            self.sendJsonResponse(client_fd, "{\"ok\":true}");
            Output.toggle(null);
            return;
        }

        // 404
        const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _ = c.send(client_fd, not_found.ptr, @intCast(not_found.len), 0);
        _ = c.close(client_fd);
    }

    fn sendStaticResponse(self: *Server, client_fd: c.SOCKET, content_type: []const u8, content: []const u8) void {
        _ = self;
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n", .{ content_type, content.len }) catch return;
        _ = c.send(client_fd, hdr.ptr, @intCast(hdr.len), 0);
        _ = c.send(client_fd, content.ptr, @intCast(content.len), 0);
        _ = c.close(client_fd);
    }

    fn sendJsonResponse(self: *Server, client_fd: c.SOCKET, json: []const u8) void {
        _ = self;
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Headers: *\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n", .{json.len}) catch return;
        _ = c.send(client_fd, hdr.ptr, @intCast(hdr.len), 0);
        _ = c.send(client_fd, json.ptr, @intCast(json.len), 0);
        _ = c.close(client_fd);
    }

    fn handleGetSettings(self: *Server, client_fd: c.SOCKET) void {
        const out_opt = self.output orelse Output.getOrCreateOutput();
        const saved_opt = Output.loadSettings();
        defer if (saved_opt) |s| c.obs_data_release(s);

        const is_active = if (out_opt) |out| out.active else false;
        const sink_c = if (saved_opt) |s| c.obs_data_get_string(s, "sink") else null;
        const sink_str = if (out_opt != null and out_opt.?.sink_ip.len > 0)
            out_opt.?.sink_ip
        else if (sink_c != null)
            std.mem.span(sink_c)
        else
            "";
        const bitrate = if (saved_opt) |s| c.obs_data_get_int(s, "bitrate") else 2500;
        const preset_c = if (saved_opt) |s| c.obs_data_get_string(s, "preset") else null;
        const preset_str = if (preset_c != null and preset_c[0] != 0)
            std.mem.span(preset_c)
        else
            "ultrafast";
        const debug_log = if (saved_opt) |s| c.obs_data_get_bool(s, "debug_logging") else false;

        const json = std.json.Stringify.valueAlloc(self.allocator, .{
            .sink = sink_str,
            .bitrate = if (bitrate > 0) bitrate else 2500,
            .preset = preset_str,
            .debug_logging = debug_log,
            .active = is_active,
        }, .{}) catch {
            self.sendJsonResponse(client_fd, "{\"error\":\"json_error\"}");
            return;
        };
        defer self.allocator.free(json);
        self.sendJsonResponse(client_fd, json);
    }

    fn handleGetDevices(self: *Server, client_fd: c.SOCKET) void {
        const out = self.output orelse Output.getOrCreateOutput();
        if (out) |o| {
            o.ensureDiscovery();
            if (o.discovery) |*disc| {
                var dev_list: std.ArrayList(Device) = .empty;
                defer {
                    for (dev_list.items) |d| d.deinit(self.allocator);
                    dev_list.deinit(self.allocator);
                }
                disc.getDevices(self.allocator, &dev_list) catch {};

                const json = std.json.Stringify.valueAlloc(self.allocator, dev_list.items, .{}) catch {
                    self.sendJsonResponse(client_fd, "[]");
                    return;
                };
                defer self.allocator.free(json);
                self.sendJsonResponse(client_fd, json);
                return;
            }
        }
        self.sendJsonResponse(client_fd, "[]");
    }

    fn handleScan(self: *Server, client_fd: c.SOCKET) void {
        const out = self.output orelse Output.getOrCreateOutput();
        if (out) |o| {
            o.ensureDiscovery();
            if (o.discovery) |*disc| {
                disc.scan(1500) catch {};
            }
        }
        self.handleGetDevices(client_fd);
    }

    const UpdateSettingsPayload = struct {
        sink: ?[]const u8 = null,
        bitrate: ?i64 = null,
        preset: ?[]const u8 = null,
        debug_logging: ?bool = null,
    };

    fn handleUpdateSettings(self: *Server, client_fd: c.SOCKET, req_slice: []const u8) void {
        const body_start = std.mem.indexOf(u8, req_slice, "\r\n\r\n");
        const body = if (body_start) |idx| req_slice[idx + 4 ..] else "";

        const parsed = std.json.parseFromSlice(UpdateSettingsPayload, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.sendJsonResponse(client_fd, "{\"error\":\"invalid_json\"}");
            return;
        };
        defer parsed.deinit();

        const saved_opt = Output.loadSettings();
        const settings = (saved_opt orelse c.obs_data_create()) orelse {
            self.sendJsonResponse(client_fd, "{\"error\":\"obs_data_error\"}");
            return;
        };
        defer c.obs_data_release(settings);
        Output.get_defaults(settings);

        if (parsed.value.sink) |s| {
            var s_buf: [256:0]u8 = undefined;
            if (std.mem.printSentinel(&s_buf, "{s}", .{s}, 0)) |sz| {
                c.obs_data_set_string(settings, "sink", sz.ptr);
            } else |_| {}
        }
        if (parsed.value.bitrate) |br| {
            c.obs_data_set_int(settings, "bitrate", @intCast(br));
        }
        if (parsed.value.preset) |p| {
            var p_buf: [64:0]u8 = undefined;
            if (std.mem.printSentinel(&p_buf, "{s}", .{p}, 0)) |pz| {
                c.obs_data_set_string(settings, "preset", pz.ptr);
            } else |_| {}
        }
        if (parsed.value.debug_logging) |dbg| {
            c.obs_data_set_bool(settings, "debug_logging", dbg);
        }

        Output.saveSettings(settings);

        if (self.output orelse Output.getOrCreateOutput()) |o| {
            o.applySettings(settings);
            c.obs_output_update(o.ptr, settings);
        }

        self.sendJsonResponse(client_fd, "{\"ok\":true}");
    }

    /// Gets the local IPv4 address that routes towards destination_ip
    pub fn getLocalIpFor(dest_ip_str: []const u8, buf: []u8) ![]const u8 {
        const udp_fd = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
        if (c.is_socket_valid(udp_fd) == 0) return error.SocketCreationFailed;
        defer _ = c.close(udp_fd);

        var dest_addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        dest_addr.sin_family = c.AF_INET;
        dest_addr.sin_port = c.htons(8009);

        var ip_z: [64:0]u8 = undefined;
        const len = @min(dest_ip_str.len, 63);
        @memcpy(ip_z[0..len], dest_ip_str[0..len]);
        ip_z[len] = 0;

        if (c.inet_pton(c.AF_INET, &ip_z, &dest_addr.sin_addr) <= 0) {
            c.blog(c.LOG_ERROR, "zobscast Server: inet_pton failed for destination '%s'", &ip_z);
            return error.InvalidDestinationIp;
        }

        if (c.connect(udp_fd, @ptrCast(&dest_addr), @sizeOf(c.sockaddr_in)) < 0) {
            c.blog(c.LOG_ERROR, "zobscast Server: routing UDP connect failed for '%s'", &ip_z);
            return error.RoutingFailed;
        }

        var local_addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        var addr_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        if (c.getsockname(udp_fd, @ptrCast(&local_addr), &addr_len) < 0) {
            return error.GetSockNameFailed;
        }

        var str_buf: [c.INET_ADDRSTRLEN]u8 = undefined;
        if (c.inet_ntop(c.AF_INET, &local_addr.sin_addr, &str_buf, c.INET_ADDRSTRLEN) == null) {
            return error.NtopFailed;
        }

        const ip_len = std.mem.indexOfScalar(u8, &str_buf, 0) orelse str_buf.len;
        if (buf.len < ip_len) return error.BufferTooSmall;
        @memcpy(buf[0..ip_len], str_buf[0..ip_len]);
        return buf[0..ip_len];
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        if (c.is_socket_valid(self.server_fd) != 0) {
            _ = c.close(self.server_fd);
            self.server_fd = c.INVALID_SOCKET_VALUE;
        }

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        self.clearClients();
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.clients.deinit(self.allocator);
        self.header_data.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
