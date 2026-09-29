const std = @import("std");
const c = @import("c");
const Output = @import("Output.zig");
const Device = @import("Discovery.zig").Device;
const root = @import("root.zig");

const settings_html = @embedFile("web/index.html");
const settings_css = @embedFile("web/style.css");
const settings_js = @embedFile("web/app.js");

pub const Server = @This();

listener: ?std.Io.net.Server = null,
port: u16 = 0,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
clients: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
client_mutex: std.Io.Mutex = .init,
client_tasks: std.Io.Group = .init,
accept_future: ?std.Io.Future(void) = null,
allocator: std.mem.Allocator,
io: std.Io,
header_data: std.ArrayListUnmanaged(u8) = .empty,
header_mutex: std.Io.Mutex = .init,
output: ?*Output = null,
debug_logging: bool = false,

pub fn init(allocator: std.mem.Allocator, output: ?*Output, io: std.Io) !*Server {
    const self = try allocator.create(Server);
    self.* = .{
        .allocator = allocator,
        .output = output,
        .io = io,
    };
    return self;
}

pub fn start(self: *Server, preferred_port: u16) !u16 {
    if (self.running.load(.monotonic)) {
        return self.port;
    }

    const io = self.io;
    var address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(preferred_port) };
    const listener = blk: {
        break :blk address.listen(io, .{ .reuse_address = true }) catch |err| {
            if (preferred_port == 0) return err;
            address.setPort(0);
            break :blk address.listen(io, .{ .reuse_address = true }) catch return err;
        };
    };

    self.port = listener.socket.address.getPort();
    self.listener = listener;
    self.running.store(true, .monotonic);

    self.accept_future = io.concurrent(acceptLoop, .{self}) catch |err| {
        listener.socket.close(io);
        self.listener = null;
        self.running.store(false, .monotonic);
        return err;
    };

    std.log.info("zobscast HTTP streaming server listening on port {d}", .{self.port});
    return self.port;
}

pub fn setHeader(self: *Server, header: []const u8) !void {
    try self.header_mutex.lock(self.io);
    defer self.header_mutex.unlock(self.io);
    self.header_data.clearRetainingCapacity();
    try self.header_data.appendSlice(self.allocator, header);
}

pub fn broadcast(self: *Server, data: []const u8) void {
    self.client_mutex.lockUncancelable(self.io);
    defer self.client_mutex.unlock(self.io);

    var i: usize = 0;
    while (i < self.clients.items.len) {
        const stream = self.clients.items[i];
        if (!writeStream(stream, self.io, data)) {
            stream.close(self.io);
            _ = self.clients.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn clearClients(self: *Server) void {
    self.client_mutex.lockUncancelable(self.io);
    defer self.client_mutex.unlock(self.io);

    for (self.clients.items) |stream| {
        stream.close(self.io);
    }
    self.clients.clearRetainingCapacity();
}

fn acceptLoop(self: *Server) void {
    while (self.running.load(.monotonic)) {
        const stream = self.listener.?.accept(self.io) catch {
            if (!self.running.load(.monotonic)) break;
            continue;
        };
        if (!self.running.load(.monotonic)) {
            stream.close(self.io);
            break;
        }

        self.client_tasks.concurrent(self.io, handleClient, .{ self, stream }) catch {
            stream.close(self.io);
        };
    }
}

fn handleClient(self: *Server, stream: std.Io.net.Stream) void {
    var req_buf: [4096]u8 = undefined;
    var read_buffers = [_][]u8{&req_buf};
    const n = stream.read(self.io, &read_buffers) catch {
        stream.close(self.io);
        return;
    };
    if (n == 0) {
        stream.close(self.io);
        return;
    }

    const req_slice = req_buf[0..@intCast(n)];
    const first_line_end = std.mem.indexOf(u8, req_slice, "\r\n") orelse req_slice.len;
    const first_line = req_slice[0..first_line_end];

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse "";
    const path = parts.next() orelse "";

    if (self.debug_logging) {
        std.log.info("zobscast HTTP: {s} {s}", .{ method, path });
    }

    // CORS preflight
    if (std.mem.eql(u8, method, "OPTIONS")) {
        const cors_hdr =
            "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type\r\n" ++
            "Connection: close\r\n\r\n";
        _ = writeStream(stream, self.io, cors_hdr);
        stream.close(self.io);
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

        if (!writeStream(stream, self.io, http_response_header)) {
            stream.close(self.io);
            return;
        }

        // Send initialization header (ftyp + moov) if available
        {
            self.header_mutex.lockUncancelable(self.io);
            if (self.header_data.items.len > 0) {
                _ = writeStream(stream, self.io, self.header_data.items);
                std.log.info("zobscast HTTP: client connected, sent init header ({d} bytes)", .{
                    self.header_data.items.len,
                });
            } else {
                std.log.warn("zobscast HTTP: client connected before init header was ready", .{});
            }
            self.header_mutex.unlock(self.io);
        }

        // Register client to receive subsequent fragments
        {
            self.client_mutex.lockUncancelable(self.io);
            self.clients.append(self.allocator, stream) catch {
                stream.close(self.io);
            };
            self.client_mutex.unlock(self.io);
        }
        return;
    }

    // Web Settings UI
    if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/settings"))) {
        self.sendStaticResponse(stream, "text/html; charset=utf-8", settings_html);
        return;
    }

    // Web Settings CSS
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/style.css")) {
        self.sendStaticResponse(stream, "text/css; charset=utf-8", settings_css);
        return;
    }

    // Web Settings JS
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/app.js")) {
        self.sendStaticResponse(stream, "application/javascript; charset=utf-8", settings_js);
        return;
    }

    // API: Get current settings
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/settings")) {
        self.handleGetSettings(stream);
        return;
    }

    // API: Get locale strings
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/locale")) {
        self.handleGetLocale(stream);
        return;
    }

    // API: Get discovered devices
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/devices")) {
        self.handleGetDevices(stream);
        return;
    }

    // API: Trigger device scan
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/scan")) {
        self.handleScan(stream);
        return;
    }

    // API: Update settings
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/settings")) {
        self.handleUpdateSettings(stream, req_slice);
        return;
    }

    // API: Toggle cast stream
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/toggle")) {
        self.sendJsonResponse(stream, "{\"ok\":true}");
        Output.toggle(null);
        return;
    }

    // 404
    const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    _ = writeStream(stream, self.io, not_found);
    stream.close(self.io);
}

fn sendStaticResponse(self: *Server, stream: std.Io.net.Stream, content_type: []const u8, content: []const u8) void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n", .{ content_type, content.len }) catch return;
    _ = writeStream(stream, self.io, hdr);
    _ = writeStream(stream, self.io, content);
    stream.close(self.io);
}

fn sendJsonResponse(self: *Server, stream: std.Io.net.Stream, json: []const u8) void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Headers: *\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n", .{json.len}) catch return;
    _ = writeStream(stream, self.io, hdr);
    _ = writeStream(stream, self.io, json);
    stream.close(self.io);
}

fn handleGetSettings(self: *Server, stream: std.Io.net.Stream) void {
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
    const enable_video = if (out_opt) |out|
        out.enable_video
    else if (saved_opt) |s|
        c.obs_data_get_bool(s, "enable_video")
    else
        true;
    const enable_audio = if (out_opt) |out|
        out.enable_audio
    else if (saved_opt) |s|
        c.obs_data_get_bool(s, "enable_audio")
    else
        true;
    const port_val = if (out_opt) |out|
        out.sink_port
    else if (saved_opt) |s| blk: {
        const p = c.obs_data_get_int(s, "port");
        break :blk if (p > 0 and p <= 65535) @as(u16, @intCast(p)) else 8009;
    } else 8009;

    const json = std.json.Stringify.valueAlloc(self.allocator, .{
        .sink = sink_str,
        .port = port_val,
        .bitrate = if (bitrate > 0) bitrate else 2500,
        .preset = preset_str,
        .debug_logging = debug_log,
        .enable_video = enable_video,
        .enable_audio = enable_audio,
        .active = is_active,
    }, .{}) catch {
        self.sendJsonResponse(stream, "{\"error\":\"json_error\"}");
        return;
    };
    defer self.allocator.free(json);
    self.sendJsonResponse(stream, json);
}

fn handleGetLocale(self: *Server, stream: std.Io.net.Stream) void {
    const json = std.json.Stringify.valueAlloc(self.allocator, .{
        .@"Zobscast.Title" = root.getLocaleString("Zobscast.Title", "Zobscast Settings"),
        .Title = root.getLocaleString("Zobscast.Title", "Zobscast Settings"),
        .@"Zobscast.Status.Inactive" = root.getLocaleString("Zobscast.Status.Inactive", "Inactive"),
        .@"Status.Inactive" = root.getLocaleString("Zobscast.Status.Inactive", "Inactive"),
        .@"Zobscast.Status.Active" = root.getLocaleString("Zobscast.Status.Active", "Casting Live"),
        .@"Status.Active" = root.getLocaleString("Zobscast.Status.Active", "Casting Live"),
        .@"Zobscast.Destination.Title" = root.getLocaleString("Zobscast.Destination.Title", "Cast Destination"),
        .@"Destination.Title" = root.getLocaleString("Zobscast.Destination.Title", "Cast Destination"),
        .@"Zobscast.Destination.FoundDevice" = root.getLocaleString("Zobscast.Destination.FoundDevice", "Found Device"),
        .@"Destination.FoundDevice" = root.getLocaleString("Zobscast.Destination.FoundDevice", "Found Device"),
        .@"Zobscast.Destination.Choose" = root.getLocaleString("Zobscast.Destination.Choose", "-- Choose Discovered Device --"),
        .@"Destination.Choose" = root.getLocaleString("Zobscast.Destination.Choose", "-- Choose Discovered Device --"),
        .@"Zobscast.Destination.Scanning" = root.getLocaleString("Zobscast.Destination.Scanning", "Scanning devices..."),
        .@"Destination.Scanning" = root.getLocaleString("Zobscast.Destination.Scanning", "Scanning devices..."),
        .@"Zobscast.Destination.Scan" = root.getLocaleString("Zobscast.Destination.Scan", "Scan"),
        .@"Destination.Scan" = root.getLocaleString("Zobscast.Destination.Scan", "Scan"),
        .@"Zobscast.Destination.ScanInProgress" = root.getLocaleString("Zobscast.Destination.ScanInProgress", "Scanning..."),
        .@"Destination.ScanInProgress" = root.getLocaleString("Zobscast.Destination.ScanInProgress", "Scanning..."),
        .@"Zobscast.Destination.IpAddress" = root.getLocaleString("Zobscast.Destination.IpAddress", "IP Address"),
        .@"Destination.IpAddress" = root.getLocaleString("Zobscast.Destination.IpAddress", "IP Address"),
        .@"Zobscast.Destination.IpPlaceholder" = root.getLocaleString("Zobscast.Destination.IpPlaceholder", "e.g. 192.168.1.100 or device name"),
        .@"Destination.IpPlaceholder" = root.getLocaleString("Zobscast.Destination.IpPlaceholder", "e.g. 192.168.1.100 or device name"),
        .@"Zobscast.Destination.Port" = root.getLocaleString("Zobscast.Destination.Port", "Port"),
        .@"Destination.Port" = root.getLocaleString("Zobscast.Destination.Port", "Port"),
        .@"Zobscast.Encoding.Title" = root.getLocaleString("Zobscast.Encoding.Title", "Video & Encoding"),
        .@"Encoding.Title" = root.getLocaleString("Zobscast.Encoding.Title", "Video & Encoding"),
        .@"Zobscast.Encoding.Bitrate" = root.getLocaleString("Zobscast.Encoding.Bitrate", "Bitrate"),
        .@"Encoding.Bitrate" = root.getLocaleString("Zobscast.Encoding.Bitrate", "Bitrate"),
        .@"Zobscast.Encoding.BitrateSuffix" = root.getLocaleString("Zobscast.Encoding.BitrateSuffix", "kbps"),
        .@"Encoding.BitrateSuffix" = root.getLocaleString("Zobscast.Encoding.BitrateSuffix", "kbps"),
        .@"Zobscast.Encoding.EnableVideo" = root.getLocaleString("Zobscast.Encoding.EnableVideo", "Video Stream"),
        .@"Encoding.EnableVideo" = root.getLocaleString("Zobscast.Encoding.EnableVideo", "Video Stream"),
        .@"Zobscast.Encoding.EnableVideoDesc" = root.getLocaleString("Zobscast.Encoding.EnableVideoDesc", "Stream OBS canvas video"),
        .@"Encoding.EnableVideoDesc" = root.getLocaleString("Zobscast.Encoding.EnableVideoDesc", "Stream OBS canvas video"),
        .@"Zobscast.Audio.Title" = root.getLocaleString("Zobscast.Audio.Title", "Audio"),
        .@"Audio.Title" = root.getLocaleString("Zobscast.Audio.Title", "Audio"),
        .@"Zobscast.Audio.EnableAudio" = root.getLocaleString("Zobscast.Audio.EnableAudio", "Audio Stream"),
        .@"Audio.EnableAudio" = root.getLocaleString("Zobscast.Audio.EnableAudio", "Audio Stream"),
        .@"Zobscast.Audio.EnableAudioDesc" = root.getLocaleString("Zobscast.Audio.EnableAudioDesc", "Stream OBS master audio"),
        .@"Audio.EnableAudioDesc" = root.getLocaleString("Zobscast.Audio.EnableAudioDesc", "Stream OBS master audio"),
        .@"Zobscast.Encoding.Preset" = root.getLocaleString("Zobscast.Encoding.Preset", "Preset"),
        .@"Encoding.Preset" = root.getLocaleString("Zobscast.Encoding.Preset", "Preset"),
        .@"Zobscast.Encoding.Preset.Ultrafast" = root.getLocaleString("Zobscast.Encoding.Preset.Ultrafast", "ultrafast (lowest delay)"),
        .@"Encoding.Preset.Ultrafast" = root.getLocaleString("Zobscast.Encoding.Preset.Ultrafast", "ultrafast (lowest delay)"),
        .@"Zobscast.Encoding.Preset.Superfast" = root.getLocaleString("Zobscast.Encoding.Preset.Superfast", "superfast"),
        .@"Encoding.Preset.Superfast" = root.getLocaleString("Zobscast.Encoding.Preset.Superfast", "superfast"),
        .@"Zobscast.Encoding.Preset.Veryfast" = root.getLocaleString("Zobscast.Encoding.Preset.Veryfast", "veryfast (recommended)"),
        .@"Encoding.Preset.Veryfast" = root.getLocaleString("Zobscast.Encoding.Preset.Veryfast", "veryfast (recommended)"),
        .@"Zobscast.Encoding.Preset.Faster" = root.getLocaleString("Zobscast.Encoding.Preset.Faster", "faster"),
        .@"Encoding.Preset.Faster" = root.getLocaleString("Zobscast.Encoding.Preset.Faster", "faster"),
        .@"Zobscast.Encoding.Preset.Fast" = root.getLocaleString("Zobscast.Encoding.Preset.Fast", "fast"),
        .@"Encoding.Preset.Fast" = root.getLocaleString("Zobscast.Encoding.Preset.Fast", "fast"),
        .@"Zobscast.Encoding.Preset.Medium" = root.getLocaleString("Zobscast.Encoding.Preset.Medium", "medium"),
        .@"Encoding.Preset.Medium" = root.getLocaleString("Zobscast.Encoding.Preset.Medium", "medium"),
        .@"Zobscast.Diagnostics.Title" = root.getLocaleString("Zobscast.Diagnostics.Title", "Diagnostics"),
        .@"Diagnostics.Title" = root.getLocaleString("Zobscast.Diagnostics.Title", "Diagnostics"),
        .@"Zobscast.Diagnostics.VerboseLogging" = root.getLocaleString("Zobscast.Diagnostics.VerboseLogging", "Verbose Logging"),
        .@"Diagnostics.VerboseLogging" = root.getLocaleString("Zobscast.Diagnostics.VerboseLogging", "Verbose Logging"),
        .@"Zobscast.Diagnostics.VerboseLoggingDesc" = root.getLocaleString("Zobscast.Diagnostics.VerboseLoggingDesc", "Log video packet stats to OBS log"),
        .@"Diagnostics.VerboseLoggingDesc" = root.getLocaleString("Zobscast.Diagnostics.VerboseLoggingDesc", "Log video packet stats to OBS log"),
        .@"Zobscast.Actions.Start" = root.getLocaleString("Zobscast.Actions.Start", "Start Casting"),
        .@"Actions.Start" = root.getLocaleString("Zobscast.Actions.Start", "Start Casting"),
        .@"Zobscast.Actions.Stop" = root.getLocaleString("Zobscast.Actions.Stop", "Stop Casting"),
        .@"Actions.Stop" = root.getLocaleString("Zobscast.Actions.Stop", "Stop Casting"),
        .@"Zobscast.Actions.Save" = root.getLocaleString("Zobscast.Actions.Save", "Save Settings"),
        .@"Actions.Save" = root.getLocaleString("Zobscast.Actions.Save", "Save Settings"),
        .@"Zobscast.Toast.Saved" = root.getLocaleString("Zobscast.Toast.Saved", "Settings saved!"),
        .@"Toast.Saved" = root.getLocaleString("Zobscast.Toast.Saved", "Settings saved!"),
        .@"Zobscast.Toast.SaveFailed" = root.getLocaleString("Zobscast.Toast.SaveFailed", "Failed to save settings"),
        .@"Toast.SaveFailed" = root.getLocaleString("Zobscast.Toast.SaveFailed", "Failed to save settings"),
        .@"Zobscast.Toast.ScanComplete" = root.getLocaleString("Zobscast.Toast.ScanComplete", "Scan complete"),
        .@"Toast.ScanComplete" = root.getLocaleString("Zobscast.Toast.ScanComplete", "Scan complete"),
        .@"Zobscast.Toast.ScanFailed" = root.getLocaleString("Zobscast.Toast.ScanFailed", "Scan failed"),
        .@"Toast.ScanFailed" = root.getLocaleString("Zobscast.Toast.ScanFailed", "Scan failed"),
        .@"Zobscast.Toast.NetworkError" = root.getLocaleString("Zobscast.Toast.NetworkError", "Network error"),
        .@"Toast.NetworkError" = root.getLocaleString("Zobscast.Toast.NetworkError", "Network error"),
    }, .{}) catch {
        self.sendJsonResponse(stream, "{}");
        return;
    };
    defer self.allocator.free(json);
    self.sendJsonResponse(stream, json);
}

fn handleGetDevices(self: *Server, stream: std.Io.net.Stream) void {
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
                self.sendJsonResponse(stream, "[]");
                return;
            };
            defer self.allocator.free(json);
            self.sendJsonResponse(stream, json);
            return;
        }
    }
    self.sendJsonResponse(stream, "[]");
}

fn handleScan(self: *Server, stream: std.Io.net.Stream) void {
    const out = self.output orelse Output.getOrCreateOutput();
    if (out) |o| {
        o.ensureDiscovery();
        if (o.discovery) |*disc| {
            disc.scan(1500) catch {};
        }
    }
    self.handleGetDevices(stream);
}

const UpdateSettingsPayload = struct {
    sink: ?[]const u8 = null,
    port: ?i64 = null,
    bitrate: ?i64 = null,
    preset: ?[]const u8 = null,
    debug_logging: ?bool = null,
    enable_video: ?bool = null,
    enable_audio: ?bool = null,
};

fn handleUpdateSettings(self: *Server, stream: std.Io.net.Stream, req_slice: []const u8) void {
    const body_start = std.mem.indexOf(u8, req_slice, "\r\n\r\n");
    const body = if (body_start) |idx| req_slice[idx + 4 ..] else "";

    const parsed = std.json.parseFromSlice(UpdateSettingsPayload, self.allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        self.sendJsonResponse(stream, "{\"error\":\"invalid_json\"}");
        return;
    };
    defer parsed.deinit();

    const saved_opt = Output.loadSettings();
    const settings = (saved_opt orelse c.obs_data_create()) orelse {
        self.sendJsonResponse(stream, "{\"error\":\"obs_data_error\"}");
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
    if (parsed.value.port) |p| {
        if (p > 0 and p <= 65535) {
            c.obs_data_set_int(settings, "port", @intCast(p));
        }
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
    if (parsed.value.enable_video) |ev| {
        c.obs_data_set_bool(settings, "enable_video", ev);
    }
    if (parsed.value.enable_audio) |ea| {
        c.obs_data_set_bool(settings, "enable_audio", ea);
    }

    Output.saveSettings(settings);

    if (self.output orelse Output.getOrCreateOutput()) |o| {
        o.applySettings(settings);
        c.obs_output_update(o.ptr, settings);
    }

    self.sendJsonResponse(stream, "{\"ok\":true}");
}

/// Gets the local IPv4 address that routes towards destination_ip:dest_port
pub fn getLocalIpFor(self: *Server, dest_ip_str: []const u8, dest_port: u16, buf: []u8) ![]const u8 {
    const destination = try std.Io.net.IpAddress.parse(dest_ip_str, dest_port);
    const route_probe = try destination.connect(self.io, .{ .mode = .dgram });
    defer route_probe.close(self.io);

    const local_ip = switch (route_probe.socket.address) {
        .ip4 => |address| address,
        .ip6 => return error.UnsupportedAddressFamily,
    };
    const local_text = try std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        local_ip.bytes[0],
        local_ip.bytes[1],
        local_ip.bytes[2],
        local_ip.bytes[3],
    });
    return local_text;
}

pub fn stop(self: *Server) void {
    self.running.store(false, .monotonic);
    if (self.listener != null) {
        const wake_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (wake_address.connect(self.io, .{ .mode = .stream })) |wake_stream| {
            wake_stream.close(self.io);
        } else |_| {}
    }

    if (self.accept_future) |*future| {
        _ = future.await(self.io);
        self.accept_future = null;
    }

    self.client_tasks.cancel(self.io);

    if (self.listener) |listener| {
        listener.socket.close(self.io);
    }
    self.listener = null;
    self.clearClients();
}

pub fn deinit(self: *Server) void {
    self.stop();
    self.clients.deinit(self.allocator);
    self.header_data.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn writeStream(stream: std.Io.net.Stream, io: std.Io, data: []const u8) bool {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(data) catch return false;
    writer.interface.flush() catch return false;
    return true;
}
