const c = @import("c");
const std = @import("std");
const Muxer = @import("ffmpeg/Muxer.zig").Muxer;
const Server = @import("stream/Server.zig").Server;
const Discovery = @import("cast/Discovery.zig").Discovery;
const Device = @import("cast/Discovery.zig").Device;
const CastClient = @import("cast/Client.zig").Client;

ptr: *c.obs_output_t,
settings: ?*c.obs_data_t = null,
active: bool = false,
sink_ip: []u8 = &[_]u8{},
server: ?*Server = null,
muxer: ?*Muxer = null,
cast_client: ?*CastClient = null,
connect_thread: ?std.Thread = null,
mutex: std.atomic.Mutex = .unlocked,
allocator: std.mem.Allocator,

var global_discovery: ?*Discovery = null;
var discovery_mutex: std.atomic.Mutex = .unlocked;
pub var debug_logging: bool = false;
var packet_count: usize = 0;

pub const info: c.obs_output_info = .{
    .id = "zobscast",
    .flags = c.OBS_OUTPUT_VIDEO | c.OBS_OUTPUT_ENCODED,
    .get_name = name,
    .create = create,
    .destroy = destroy,
    .start = start,
    .stop = stop,
    .encoded_packet = get_data,
    .update = update,
    .get_defaults = get_defaults,
    .get_properties = get_properties,
    .encoded_video_codecs = "h264",
};

fn ensureDiscovery() void {
    while (!discovery_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer discovery_mutex.unlock();

    if (global_discovery == null) {
        global_discovery = Discovery.init(std.heap.c_allocator) catch null;
    }
}

pub fn deinitDiscovery() void {
    while (!discovery_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer discovery_mutex.unlock();

    if (global_discovery) |disc| {
        disc.deinit();
        global_discovery = null;
    }
}

pub fn cleanIp(input: []const u8) []const u8 {
    var s = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, s, '(')) |open_idx| {
        if (std.mem.indexOfScalarPos(u8, s, open_idx, ')')) |close_idx| {
            s = std.mem.trim(u8, s[open_idx + 1 .. close_idx], " \t\r\n");
        }
    }
    if (std.mem.indexOfScalar(u8, s, ':')) |colon_idx| {
        s = s[0..colon_idx];
    }
    return s;
}

pub fn getConfigPath() ?[*c]u8 {
    const root = @import("root.zig");
    return c.obs_module_get_config_path(root.obs_current_module(), "zobscast.json");
}

pub fn loadSettings() ?*c.obs_data_t {
    const path = getConfigPath();
    if (path) |p| {
        defer c.bfree(p);
        return c.obs_data_create_from_json_file(p);
    }
    return null;
}

pub fn saveSettings(settings: *c.obs_data_t) void {
    const path = getConfigPath();
    if (path) |p| {
        defer c.bfree(p);
        const path_slice = std.mem.span(p);
        if (std.fs.path.dirname(path_slice)) |dir| {
            var dir_buf: [512:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir})) |dir_z| {
                _ = c.os_mkdirs(dir_z.ptr);
            } else |_| {}
        }
        _ = c.obs_data_save_json(settings, p);
    }
}

pub fn ensureEncoder(output: *c.obs_output_t) void {
    if (c.obs_output_get_video_encoder(output) != null) return;

    const saved = loadSettings();
    const settings = saved orelse c.obs_data_create();
    defer c.obs_data_release(settings);

    const enc_settings = c.obs_data_create();
    defer c.obs_data_release(enc_settings);

    const bitrate = c.obs_data_get_int(settings, "bitrate");
    const br: c_longlong = if (bitrate > 0) bitrate else 2500;
    c.obs_data_set_int(enc_settings, "bitrate", br);

    const preset_raw = c.obs_data_get_string(settings, "encoder_preset");
    const preset: [*c]const u8 = if (preset_raw != null and preset_raw[0] != 0)
        preset_raw
    else
        "veryfast";
    c.obs_data_set_string(enc_settings, "preset", preset);
    c.obs_data_set_string(enc_settings, "profile", "baseline");
    c.obs_data_set_int(enc_settings, "keyint_sec", 1);

    const enc_id: [*c]const u8 = "obs_x264";
    const enc = c.obs_video_encoder_create(enc_id, "zobscast_enc", enc_settings, null);
    if (enc == null) {
        c.blog(c.LOG_ERROR, "zobscast: failed to create video encoder '%s'", enc_id);
        return;
    }
    c.obs_encoder_set_video(enc.?, c.obs_get_video());
    c.obs_output_set_video_encoder(output, enc.?);
    // Note: Do NOT call obs_encoder_release here! The encoder must remain referenced
    // while attached to the output.

    const check = c.obs_output_get_video_encoder(output);
    c.blog(c.LOG_INFO, "zobscast: attached video encoder '%s' (%lld kbps, preset=%s, enc=%p, verified=%p)", enc_id, br, preset, enc, check);
}

pub fn toggle(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast toggle");
    const output = c.obs_get_output_by_name(info.id);
    if (output) |out| {
        defer c.obs_output_release(out);
        if (c.obs_output_active(out)) {
            c.obs_output_stop(out);
        } else {
            ensureEncoder(out);
            _ = c.obs_output_start(out);
        }
    } else {
        autostart() catch |err| {
            c.blog(c.LOG_ERROR, "zobscast autostart error: %s", @errorName(err).ptr);
        };
    }
}

pub fn autostart() !void {
    const existing = c.obs_get_output_by_name(info.id);
    if (existing) |out| {
        defer c.obs_output_release(out);
        if (!c.obs_output_active(out)) {
            ensureEncoder(out);
            _ = c.obs_output_start(out);
        }
        return;
    }

    const saved_settings = loadSettings();
    const settings = saved_settings orelse c.obs_data_create();
    defer c.obs_data_release(settings);
    get_defaults(settings);

    const output = c.obs_output_create(info.id, info.id, settings, null);
    if (output == null) {
        c.blog(c.LOG_ERROR, "zobscast failed to create output");
        return;
    }

    ensureEncoder(output.?);
    const started = c.obs_output_start(output.?);
    c.blog(c.LOG_INFO, "zobscast autostart: started=%d", @as(c_int, if (started) 1 else 0));
}

fn name(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = ctx;
    return "zobscast";
}

fn create(settings: ?*c.struct_obs_data, ptr: ?*c.struct_obs_output) callconv(.c) ?*anyopaque {
    c.blog(c.LOG_INFO, "zobscast create");
    const self = std.heap.c_allocator.create(@This()) catch @panic("zobscast create alloc error");
    self.* = .{
        .ptr = ptr.?,
        .settings = settings,
        .allocator = std.heap.c_allocator,
    };

    if (settings) |s| {
        c.obs_data_addref(s);
        self.applySettings(s);
    }

    if (self.sink_ip.len == 0) {
        const saved = loadSettings();
        if (saved) |s| {
            defer c.obs_data_release(s);
            self.applySettings(s);
        }
    }

    return self;
}

fn destroy(ctx: ?*anyopaque) callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast destroy");
    const self: *@This() = @ptrCast(@alignCast(ctx.?));

    stop(ctx, 0);

    if (self.settings) |s| {
        c.obs_data_release(s);
    }
    if (self.sink_ip.len > 0) {
        self.allocator.free(self.sink_ip);
    }

    self.allocator.destroy(self);
    c.blog(c.LOG_INFO, "zobscast destroy finished");
}

fn update(ctx: ?*anyopaque, settings: ?*c.obs_data_t) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(ctx.?));
    if (settings) |s| {
        self.applySettings(s);
        saveSettings(s);
    }
}

fn applySettings(self: *@This(), settings: *c.obs_data_t) void {
    debug_logging = c.obs_data_get_bool(settings, "debug_logging");
    const sink_str = c.obs_data_get_string(settings, "sink");
    if (sink_str != null and sink_str[0] != 0) {
        const slice = std.mem.span(sink_str);
        if (self.sink_ip.len > 0) {
            self.allocator.free(self.sink_ip);
        }
        self.sink_ip = self.allocator.dupe(u8, slice) catch &[_]u8{};
        c.blog(c.LOG_INFO, "zobscast updated sink to: %s", self.sink_ip.ptr);
    }
}

pub fn get_defaults(settings: ?*c.obs_data_t) callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast get_defaults");
    c.obs_data_set_default_string(settings, "sink", "");
    c.obs_data_set_default_int(settings, "bitrate", 2500);
    c.obs_data_set_default_string(settings, "preset", "ultrafast");
    c.obs_data_set_default_string(settings, "rate_control", "CRF");
    c.obs_data_set_default_bool(settings, "debug_logging", false);
}

pub fn get_properties(ctx: ?*anyopaque) callconv(.c) ?*c.obs_properties_t {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast get_properties");
    const props = c.obs_properties_create();

    const is_active = if (c.obs_get_output_by_name(info.id)) |out| blk: {
        defer c.obs_output_release(out);
        break :blk c.obs_output_active(out);
    } else false;

    const status_text: [*c]const u8 = if (is_active)
        "● CASTING ACTIVE (Streaming live to sink)"
    else
        "○ INACTIVE (Not casting)";

    _ = c.obs_properties_add_text(
        props,
        "cast_status",
        status_text,
        c.OBS_TEXT_INFO,
    );

    const list = c.obs_properties_add_list(
        props,
        "sink",
        "Cast Destination (Discovered Device or IP)",
        c.OBS_COMBO_TYPE_EDITABLE,
        c.OBS_COMBO_FORMAT_STRING,
    );

    // Initial mDNS discovery if needed
    ensureDiscovery();
    if (global_discovery) |disc| {
        disc.scan(800) catch {};

        var dev_list: std.ArrayList(Device) = .empty;
        defer {
            for (dev_list.items) |d| d.deinit(std.heap.c_allocator);
            dev_list.deinit(std.heap.c_allocator);
        }
        disc.getDevices(std.heap.c_allocator, &dev_list) catch {};

        for (dev_list.items) |d| {
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s} ({s})", .{ d.name, d.ip }) catch d.name;
            var ip_z: [64:0]u8 = undefined;
            const ip_slice = std.fmt.bufPrintZ(&ip_z, "{s}", .{d.ip}) catch d.ip;
            _ = c.obs_property_list_add_string(list, label.ptr, ip_slice.ptr);
        }
    }

    _ = c.obs_properties_add_button(
        props,
        "refresh_devices",
        "Scan for Devices",
        refreshClicked,
    );

    _ = c.obs_properties_add_int(
        props,
        "bitrate",
        "Bitrate (kbps)",
        500,
        50000,
        250,
    );

    const preset_prop = c.obs_properties_add_list(
        props,
        "preset",
        "Encoder Preset",
        c.OBS_COMBO_TYPE_LIST,
        c.OBS_COMBO_FORMAT_STRING,
    );
    _ = c.obs_property_list_add_string(preset_prop, "ultrafast", "ultrafast");
    _ = c.obs_property_list_add_string(preset_prop, "superfast", "superfast");
    _ = c.obs_property_list_add_string(preset_prop, "veryfast", "veryfast");
    _ = c.obs_property_list_add_string(preset_prop, "faster", "faster");
    _ = c.obs_property_list_add_string(preset_prop, "fast", "fast");
    _ = c.obs_property_list_add_string(preset_prop, "medium", "medium");

    _ = c.obs_properties_add_bool(
        props,
        "debug_logging",
        "Enable Verbose Debug Logging",
    );

    return props;
}

fn refreshClicked(props: ?*c.obs_properties_t, property: ?*c.obs_property_t, data: ?*anyopaque) callconv(.c) bool {
    _ = props;
    _ = property;
    _ = data;
    c.blog(c.LOG_INFO, "zobscast scanning for devices...");
    ensureDiscovery();
    if (global_discovery) |disc| {
        disc.scan(1500) catch |err| {
            c.blog(c.LOG_ERROR, "zobscast discovery error: %s", @errorName(err).ptr);
        };
    }
    return true;
}

fn start(ctx: ?*anyopaque) callconv(.c) bool {
    c.blog(c.LOG_INFO, "zobscast start");
    const self: *@This() = @ptrCast(@alignCast(ctx.?));

    while (!self.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer self.mutex.unlock();

    if (self.active) return true;

    const venc = c.obs_output_get_video_encoder(self.ptr);
    const act = c.obs_output_active(self.ptr);
    c.blog(c.LOG_INFO, "zobscast start check: ptr=%p venc=%p active=%d", self.ptr, venc, @as(c_int, if (act) 1 else 0));

    // Check if output can begin capture and initialize encoders (must be done in start callback)
    if (!c.obs_output_can_begin_data_capture(self.ptr, 0)) {
        c.blog(c.LOG_ERROR, "zobscast start: obs_output_can_begin_data_capture returned false (venc=%p active=%d)", venc, @as(c_int, if (act) 1 else 0));
        return false;
    }
    if (!c.obs_output_initialize_encoders(self.ptr, 0)) {
        c.blog(c.LOG_ERROR, "zobscast start: obs_output_initialize_encoders returned false");
        return false;
    }

    // Join any leftover thread from a previous start
    if (self.connect_thread) |t| {
        t.join();
        self.connect_thread = null;
    }

    // Spawn the connection thread — network connection and begin_data_capture
    // happen in this background thread.
    self.connect_thread = std.Thread.spawn(.{}, connectThread, .{self}) catch |err| {
        c.blog(c.LOG_ERROR, "zobscast: failed to spawn connect thread: %s", @errorName(err).ptr);
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return false;
    };
    return true;
}

fn connectThread(self: *@This()) void {
    while (!self.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer self.mutex.unlock();

    // If sink_ip is still empty, try loading from saved settings
    if (self.sink_ip.len == 0) {
        const saved = loadSettings();
        if (saved) |s| {
            defer c.obs_data_release(s);
            self.applySettings(s);
        }
    }

    // Determine target IP
    var raw_target: []const u8 = self.sink_ip;
    if (raw_target.len == 0 and self.settings != null) {
        const s = c.obs_data_get_string(self.settings.?, "sink");
        if (s != null and s[0] != 0) {
            raw_target = std.mem.span(s);
        }
    }

    // Fallback: pick first discovered device if none chosen
    if (raw_target.len == 0) {
        ensureDiscovery();
        if (global_discovery) |disc| {
            disc.scan(1000) catch {};
            while (!disc.mutex.tryLock()) {
                std.Thread.yield() catch {};
            }
            if (disc.devices.items.len > 0) {
                raw_target = disc.devices.items[0].ip;
            }
            disc.mutex.unlock();
        }
    }

    const target_ip = cleanIp(raw_target);
    if (target_ip.len == 0) {
        c.blog(c.LOG_ERROR, "zobscast: no cast sink selected! Open Output properties to select or enter a device IP.");
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_BAD_PATH);
        return;
    }

    c.blog(c.LOG_INFO, "zobscast start: casting to %.*s (from setting '%.*s')", @as(c_int, @intCast(target_ip.len)), target_ip.ptr, @as(c_int, @intCast(raw_target.len)), raw_target.ptr);

    // 1. Start HTTP Server
    const server = Server.init(self.allocator) catch |err| {
        c.blog(c.LOG_ERROR, "zobscast: failed to init HTTP server: %s", @errorName(err).ptr);
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };
    self.server = server;
    _ = server.start(0) catch |err| {
        c.blog(c.LOG_ERROR, "zobscast: failed to start HTTP server: %s", @errorName(err).ptr);
        server.deinit();
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };

    // 2. Initialize FFmpeg Muxer
    var width: u32 = c.obs_output_get_width(self.ptr);
    var height: u32 = c.obs_output_get_height(self.ptr);
    if (width == 0 or height == 0) {
        if (c.obs_get_video()) |v| {
            width = c.video_output_get_width(v);
            height = c.video_output_get_height(v);
        }
    }
    if (width == 0 or height == 0) {
        width = 1920;
        height = 1080;
    }

    const venc = c.obs_output_get_video_encoder(self.ptr);
    var extra_data_ptr: [*c]u8 = null;
    var extra_data_size: usize = 0;
    var extradata_slice: ?[]const u8 = null;

    if (venc) |ve| {
        if (c.obs_encoder_get_extra_data(ve, &extra_data_ptr, &extra_data_size) and extra_data_ptr != null and extra_data_size > 0) {
            c.blog(c.LOG_INFO, "zobscast: got video encoder extradata (%zu bytes)", extra_data_size);
            extradata_slice = extra_data_ptr[0..extra_data_size];
        } else {
            c.blog(c.LOG_WARNING, "zobscast: obs_encoder_get_extra_data returned no data");
        }
    }

    const muxer = Muxer.init(self.allocator, onMuxedData, self, width, height, extradata_slice) catch |err| {
        c.blog(c.LOG_ERROR, "zobscast: failed to initialize FFmpeg muxer: %s", @errorName(err).ptr);
        server.deinit();
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
        return;
    };
    self.muxer = muxer;

    // 3. Set initialization header
    server.setHeader(muxer.getHeader());

    // 4. Resolve local IP address facing destination
    var ip_buf: [64]u8 = undefined;
    const local_ip = Server.getLocalIpFor(target_ip, &ip_buf) catch "127.0.0.1";

    var url_buf: [256]u8 = undefined;
    const stream_url = std.fmt.bufPrintZ(&url_buf, "http://{s}:{d}/live.mp4", .{ local_ip, server.port }) catch "http://127.0.0.1:8010/live.mp4";
    c.blog(c.LOG_INFO, "zobscast: stream endpoint prepared at %s", stream_url.ptr);

    // 5. Begin data capture (encoders already initialized in start())
    if (!c.obs_output_begin_data_capture(self.ptr, 0)) {
        c.blog(c.LOG_ERROR, "zobscast: obs_output_begin_data_capture failed");
        muxer.deinit();
        server.deinit();
        self.muxer = null;
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
        return;
    }

    // 6. Connect CastClient and request playback
    const cast_client = CastClient.init(self.allocator, target_ip, 8009) catch |err| {
        c.blog(c.LOG_ERROR, "zobscast: failed to init Cast client: %s", @errorName(err).ptr);
        c.obs_output_end_data_capture(self.ptr);
        muxer.deinit();
        server.deinit();
        self.muxer = null;
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };
    self.cast_client = cast_client;

    cast_client.startCast(stream_url) catch |err| {
        c.blog(c.LOG_ERROR, "zobscast: failed to connect to Chromecast: %s", @errorName(err).ptr);
        c.obs_output_end_data_capture(self.ptr);
        cast_client.deinit();
        muxer.deinit();
        server.deinit();
        self.cast_client = null;
        self.muxer = null;
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };

    self.active = true;
    c.blog(c.LOG_INFO, "zobscast stream live at %s", stream_url.ptr);
    const gui = @import("gui.zig");
    gui.setActive(true);
}

fn onMuxedData(ctx: ?*anyopaque, data: []const u8) void {
    if (ctx == null) return;
    const self: *@This() = @ptrCast(@alignCast(ctx.?));
    if (self.server) |srv| {
        srv.broadcast(data);
    }
}

fn stop(ctx: ?*anyopaque, it: u64) callconv(.c) void {
    _ = it;
    c.blog(c.LOG_INFO, "zobscast stop");
    const self: *@This() = @ptrCast(@alignCast(ctx.?));

    // Wait for any in-progress connection attempt to finish.
    // Must NOT hold self.mutex while joining — connectThread also locks it.
    if (self.connect_thread) |t| {
        t.join();
        self.connect_thread = null;
    }

    while (!self.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer self.mutex.unlock();

    if (self.active) {
        c.obs_output_end_data_capture(self.ptr);
        self.active = false;
        const gui = @import("gui.zig");
        gui.setActive(false);
    }

    if (self.cast_client) |client| {
        client.deinit();
        self.cast_client = null;
    }

    if (self.muxer) |muxer| {
        muxer.deinit();
        self.muxer = null;
    }

    if (self.server) |srv| {
        srv.deinit();
        self.server = null;
    }

    c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_SUCCESS);
}

fn get_data(ctx: ?*anyopaque, d: [*c]c.struct_encoder_packet) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(ctx.?));
    if (!self.active or d == null or d.*.data == null or d.*.size == 0) {
        return;
    }

    packet_count +%= 1;
    if (debug_logging and (packet_count % 120 == 0)) {
        c.blog(
            c.LOG_INFO,
            "zobscast packet #%u: size=%u pts=%ld dts=%ld keyframe=%d",
            @as(c_uint, @intCast(packet_count)),
            @as(c_uint, @intCast(d.*.size)),
            d.*.pts,
            d.*.dts,
            @as(c_int, if (d.*.keyframe) 1 else 0),
        );
    }

    if (self.muxer) |muxer| {
        muxer.writePacket(
            d.*.data,
            d.*.size,
            d.*.pts,
            d.*.dts,
            d.*.keyframe,
            d.*.timebase_num,
            d.*.timebase_den,
        ) catch |err| {
            c.blog(c.LOG_ERROR, "zobscast muxer writePacket error: %s", @errorName(err).ptr);
        };
    }
}
