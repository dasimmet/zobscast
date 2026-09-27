const std = @import("std");
const c = @import("c");

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

    pub fn init(allocator: std.mem.Allocator) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn start(self: *Server, preferred_port: u16) !u16 {
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (c.is_socket_valid(fd) == 0) return error.SocketCreationFailed;

        var opt: c_int = 1;
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, @ptrCast(&opt), @sizeOf(c_int));

        var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        addr.sin_family = c.AF_INET;
        c.set_inaddr_any(&addr);

        // Try preferred port first, fallback to 0 (ephemeral port)
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

            // Low-latency socket tuning: disable Nagle's algorithm and limit buffer backlog
            var nodelay: c_int = 1;
            _ = c.setsockopt(client_fd, c.IPPROTO_TCP, c.TCP_NODELAY, @ptrCast(&nodelay), @sizeOf(c_int));
            var sndbuf: c_int = 128 * 1024;
            _ = c.setsockopt(client_fd, c.SOL_SOCKET, c.SO_SNDBUF, @ptrCast(&sndbuf), @sizeOf(c_int));

            // Handle client in thread
            _ = std.Thread.spawn(.{}, handleClient, .{ self, client_fd }) catch {
                _ = c.close(client_fd);
            };
        }
    }

    fn handleClient(self: *Server, client_fd: c.SOCKET) void {
        // Read HTTP request line
        var req_buf: [1024]u8 = undefined;
        const n = c.recv(client_fd, &req_buf, req_buf.len, 0);
        if (n <= 0) {
            _ = c.close(client_fd);
            return;
        }

        const req_slice = req_buf[0..@intCast(n)];
        const first_line_end = std.mem.indexOf(u8, req_slice, "\r\n") orelse req_slice.len;
        c.blog(c.LOG_INFO, "zobscast HTTP: request '%.*s'", @as(c_int, @intCast(first_line_end)), req_slice.ptr);

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

        while (!self.client_mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        for (self.clients.items) |cfd| {
            _ = c.close(cfd);
        }
        self.clients.clearRetainingCapacity();
        self.client_mutex.unlock();
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.clients.deinit(self.allocator);
        self.header_data.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
