const c = @import("c");
const std = @import("std");
const root = @import("root.zig");
const gui = @import("gui.zig");
const Muxer = @import("Muxer.zig");
const Server = @import("Server.zig");
const Discovery = @import("Discovery.zig");
const Device = Discovery.Device;
const Client = @import("Client.zig");
const Output = @This();

ptr: *c.obs_output_t,
settings: ?*c.obs_data_t = null,
active: bool = false,
sink_ip: []u8 = &[_]u8{},
sink_port: u16 = 8009,
discovery: ?Discovery = null,
server: ?*Server = null,
muxer: ?*Muxer = null,
cast_client: ?*Client = null,
connect_future: ?std.Io.Future(void) = null,
mutex: std.Io.Mutex = .init,
discovery_mutex: std.Io.Mutex = .init,
debug_logging: bool = false,
enable_video: bool = true,
enable_audio: bool = true,
packet_count: usize = 0,
allocator: std.mem.Allocator,
threaded_io: std.Io.Threaded,

pub const info: c.obs_output_info = .{
    .id = "zobscast",
    .flags = c.OBS_OUTPUT_VIDEO | c.OBS_OUTPUT_AUDIO | c.OBS_OUTPUT_ENCODED,
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
    .encoded_audio_codecs = "aac",
};

pub fn ensureDiscovery(self: *Output) void {
    const io = self.threaded_io.io();
    self.discovery_mutex.lockUncancelable(io);
    defer self.discovery_mutex.unlock(io);

    if (self.discovery == null) {
        self.discovery = Discovery.init(
            self.allocator,
            io,
        );
    }
}

pub fn deinitDiscovery(self: *Output) void {
    const io = self.threaded_io.io();
    self.discovery_mutex.lockUncancelable(io);
    defer self.discovery_mutex.unlock(io);

    if (self.discovery) |*disc| {
        disc.deinit();
        self.discovery = null;
    }
}

const ObsContextData = extern struct {
    name: ?[*:0]u8,
    uuid: ?[*:0]const u8,
    data: ?*anyopaque,
};

pub fn getOutputData(out: *c.obs_output_t) ?*Output {
    const ctx: *const ObsContextData = @ptrCast(@alignCast(out));
    if (ctx.data) |d| {
        return @ptrCast(@alignCast(d));
    }
    return null;
}

var active_instance: ?*Output = null;

pub fn getOrCreateOutput() ?*Output {
    if (active_instance) |inst| return inst;

    var out = c.obs_get_output_by_name(info.id);
    if (out == null) {
        const saved_settings = loadSettings();
        const settings = saved_settings orelse c.obs_data_create();
        defer c.obs_data_release(settings);
        get_defaults(settings);
        out = c.obs_output_create(info.id, info.id, settings, null);
    } else {
        c.obs_output_release(out.?);
    }

    if (active_instance) |inst| return inst;

    if (out) |o| {
        return getOutputData(o);
    }
    return null;
}

fn ensureHttpServerUnlocked(self: *Output) !u16 {
    if (self.server) |srv| {
        if (srv.running.load(.monotonic)) {
            return srv.port;
        }
    }

    const srv = try Server.init(
        self.allocator,
        self,
        self.threaded_io.io(),
    );

    self.server = srv;
    const port = srv.start(0) catch |err| {
        srv.deinit();
        self.server = null;
        return err;
    };
    return port;
}

pub fn ensureHttpServer(self: *Output) !u16 {
    const io = self.threaded_io.io();
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);

    return self.ensureHttpServerUnlocked();
}

pub fn getSettingsUrl(self: *Output, buf: []u8) ![:0]const u8 {
    const port = try self.ensureHttpServer();
    return std.mem.printSentinel(buf, "http://127.0.0.1:{d}/settings", .{port}, 0);
}

pub fn parseTarget(input: []const u8, default_port: u16) struct { ip: []const u8, port: u16 } {
    var s = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, s, '(')) |open_idx| {
        if (std.mem.indexOfScalarPos(u8, s, open_idx, ')')) |close_idx| {
            s = std.mem.trim(u8, s[open_idx + 1 .. close_idx], " \t\r\n");
        }
    }
    var port = default_port;
    if (std.mem.indexOfScalar(u8, s, ':')) |colon_idx| {
        const port_str = s[colon_idx + 1 ..];
        if (std.fmt.parseInt(u16, port_str, 10)) |p| {
            port = p;
        } else |_| {}
        s = s[0..colon_idx];
    }
    return .{ .ip = s, .port = port };
}

pub fn cleanIp(input: []const u8) []const u8 {
    return parseTarget(input, 8009).ip;
}

pub fn getConfigPath() ?[*c]u8 {
    return c.obs_module_get_config_path(root.obs_current_module(), "zobscast.json");
}

pub fn loadSettings() ?*c.obs_data_t {
    const path = getConfigPath();
    if (path) |p| {
        defer c.bfree(p);
        const data = c.obs_data_create_from_json_file(p);
        if (data) |d| {
            get_defaults(d);
            return d;
        }
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
            if (std.mem.printSentinel(&dir_buf, "{s}", .{dir}, 0)) |dir_z| {
                _ = c.os_mkdirs(dir_z.ptr);
            } else |_| {}
        }
        _ = c.obs_data_save_json(settings, p);
    }
}

pub fn ensureVideoEncoder(output: *c.obs_output_t) void {
    if (c.obs_output_get_video_encoder(output) != null) return;

    const saved = loadSettings();
    const settings = saved orelse c.obs_data_create();
    defer c.obs_data_release(settings);

    const enc_settings = c.obs_data_create();
    defer c.obs_data_release(enc_settings);

    const bitrate = c.obs_data_get_int(settings, "bitrate");
    const br: c_longlong = if (bitrate > 0) bitrate else 2500;
    c.obs_data_set_int(enc_settings, "bitrate", br);

    const preset_raw = c.obs_data_get_string(settings, "preset");
    const preset: [*c]const u8 = if (preset_raw != null and preset_raw[0] != 0)
        preset_raw
    else
        "ultrafast";
    c.obs_data_set_string(enc_settings, "preset", preset);
    c.obs_data_set_string(enc_settings, "tune", "zerolatency");
    c.obs_data_set_string(enc_settings, "profile", "baseline");
    c.obs_data_set_int(enc_settings, "keyint_sec", 1);
    c.obs_data_set_int(enc_settings, "bf", 0);

    const enc_id: [*c]const u8 = "obs_x264";
    const enc = c.obs_video_encoder_create(enc_id, "zobscast_enc", enc_settings, null);
    if (enc == null) {
        std.log.err("zobscast: failed to create video encoder '{s}'", .{enc_id});
        return;
    }
    c.obs_encoder_set_video(enc.?, c.obs_get_video());
    c.obs_output_set_video_encoder(output, enc.?);
    // Note: Do NOT call obs_encoder_release here! The encoder must remain referenced
    // while attached to the output.

    const check = c.obs_output_get_video_encoder(output);
    std.log.info("zobscast: attached video encoder '{s}' ({d} kbps, preset={s}, tune=zerolatency, enc={?*}, verified={?*})", .{ enc_id, br, preset, enc, check });
}

pub fn ensureAudioEncoder(output: *c.obs_output_t) void {
    if (c.obs_output_get_audio_encoder(output, 0) != null) return;

    const saved = loadSettings();
    const settings = saved orelse c.obs_data_create();
    defer c.obs_data_release(settings);

    const aenc_settings = c.obs_data_create();
    defer c.obs_data_release(aenc_settings);

    const audio_bitrate = c.obs_data_get_int(settings, "audio_bitrate");
    const abr: c_longlong = if (audio_bitrate > 0) audio_bitrate else 160;
    c.obs_data_set_int(aenc_settings, "bitrate", abr);

    const aenc_id: [*c]const u8 = "ffmpeg_aac";
    const aenc = c.obs_audio_encoder_create(aenc_id, "zobscast_aenc", aenc_settings, 0, null);
    if (aenc == null) {
        std.log.err("zobscast: failed to create audio encoder '{s}'", .{aenc_id});
        return;
    }
    const audio = c.obs_get_audio();
    if (audio == null) {
        std.log.err("zobscast: obs_get_audio returned null", .{});
        return;
    }
    c.obs_encoder_set_audio(aenc.?, audio);
    c.obs_output_set_audio_encoder(output, aenc.?, 0);
    // Note: Do NOT call obs_encoder_release here! The encoder must remain referenced
    // while attached to the output.

    const check = c.obs_output_get_audio_encoder(output, 0);
    std.log.info("zobscast: attached audio encoder '{s}' ({d} kbps, aenc={?*}, verified={?*})", .{ aenc_id, abr, aenc, check });
}

pub fn ensureEncoder(output: *c.obs_output_t) void {
    ensureVideoEncoder(output);
    ensureAudioEncoder(output);
}

pub fn toggle(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    std.log.info("zobscast toggle", .{});
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
            std.log.err("zobscast autostart error: {}", .{err});
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
        std.log.err("zobscast failed to create output", .{});
        return;
    }

    ensureEncoder(output.?);
    const started = c.obs_output_start(output.?);
    std.log.info("zobscast autostart: started={}", .{started});
}

fn name(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = ctx;
    return "zobscast";
}

fn create(settings: ?*c.struct_obs_data, ptr: ?*c.struct_obs_output) callconv(.c) ?*anyopaque {
    std.log.info("zobscast output create", .{});
    const self = std.heap.c_allocator.create(Output) catch @panic("zobscast create alloc error");

    self.* = .{
        .ptr = ptr.?,
        .settings = settings,
        .allocator = std.heap.c_allocator,
        .threaded_io = std.Io.Threaded.init(std.heap.c_allocator, .{}),
    };
    active_instance = self;

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
    std.log.info("zobscast destroy", .{});
    const self: *Output = @ptrCast(@alignCast(ctx.?));

    if (active_instance == self) {
        active_instance = null;
    }

    stop(ctx, 0);

    if (self.server) |srv| {
        srv.deinit();
        self.server = null;
    }
    self.threaded_io.deinit();

    if (self.settings) |s| {
        c.obs_data_release(s);
    }
    if (self.sink_ip.len > 0) {
        self.allocator.free(self.sink_ip);
    }

    self.allocator.destroy(self);
    std.log.info("zobscast destroy finished", .{});
}

fn update(ctx: ?*anyopaque, settings: ?*c.obs_data_t) callconv(.c) void {
    const self: *Output = @ptrCast(@alignCast(ctx.?));
    if (settings) |s| {
        self.applySettings(s);
        saveSettings(s);
    }
}

pub fn applySettings(self: *Output, settings: *c.obs_data_t) void {
    self.debug_logging = c.obs_data_get_bool(settings, "debug_logging");
    self.enable_video = c.obs_data_get_bool(settings, "enable_video");
    self.enable_audio = c.obs_data_get_bool(settings, "enable_audio");
    const port_val = c.obs_data_get_int(settings, "port");
    if (port_val > 0 and port_val <= 65535) {
        self.sink_port = @intCast(port_val);
    }
    const sink_str = c.obs_data_get_string(settings, "sink");
    if (sink_str != null and sink_str[0] != 0) {
        const parsed = parseTarget(std.mem.span(sink_str), self.sink_port);
        if (self.sink_ip.len > 0) {
            self.allocator.free(self.sink_ip);
        }
        self.sink_ip = self.allocator.dupe(u8, parsed.ip) catch &[_]u8{};
        self.sink_port = parsed.port;
        std.log.info("zobscast updated sink to: {s}:{d}", .{ self.sink_ip, self.sink_port });
    }
}

pub fn get_defaults(settings: ?*c.obs_data_t) callconv(.c) void {
    std.log.info("zobscast get_defaults", .{});
    c.obs_data_set_default_string(settings, "sink", "");
    c.obs_data_set_default_int(settings, "port", 8009);
    c.obs_data_set_default_int(settings, "bitrate", 2500);
    c.obs_data_set_default_string(settings, "preset", "ultrafast");
    c.obs_data_set_default_string(settings, "rate_control", "CRF");
    c.obs_data_set_default_bool(settings, "debug_logging", false);
    c.obs_data_set_default_bool(settings, "enable_video", true);
    c.obs_data_set_default_bool(settings, "enable_audio", true);
}

pub fn get_properties(ctx: ?*anyopaque) callconv(.c) ?*c.obs_properties_t {
    std.log.info("zobscast get_properties", .{});
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

    _ = c.obs_properties_add_button(
        props,
        "refresh_devices",
        "Scan for Devices",
        refreshClicked,
    );

    _ = c.obs_properties_add_int(
        props,
        "port",
        "Cast Port",
        1,
        65535,
        1,
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
        "enable_video",
        "Enable Video Output",
    );

    _ = c.obs_properties_add_bool(
        props,
        "enable_audio",
        "Enable Audio Output",
    );

    _ = c.obs_properties_add_bool(
        props,
        "debug_logging",
        "Enable Verbose Debug Logging",
    );

    const self: *Output = @ptrCast(@alignCast(ctx));

    // Initial mDNS discovery if needed
    self.ensureDiscovery();
    if (self.discovery) |*disc| {
        disc.scan(800) catch {};

        var dev_list: std.ArrayList(Device) = .empty;
        defer {
            for (dev_list.items) |d| d.deinit(std.heap.c_allocator);
            dev_list.deinit(std.heap.c_allocator);
        }
        disc.getDevices(std.heap.c_allocator, &dev_list) catch {};

        for (dev_list.items) |d| {
            var label_buf: [256]u8 = undefined;
            const label = std.mem.printSentinel(
                &label_buf,
                "{s} ({s}:{d})",
                .{ d.name, d.ip, d.port },
                0,
            ) catch d.name;
            var ip_z: [64:0]u8 = undefined;
            const ip_slice = std.mem.printSentinel(
                &ip_z,
                "{s}:{d}",
                .{ d.ip, d.port },
                0,
            ) catch d.ip;
            _ = c.obs_property_list_add_string(list, label.ptr, ip_slice.ptr);
        }
    }

    return props;
}

fn refreshClicked(props: ?*c.obs_properties_t, property: ?*c.obs_property_t, data: ?*anyopaque) callconv(.c) bool {
    _ = props;
    _ = property;
    const self: *Output = @ptrCast(@alignCast(data));
    std.log.info("zobscast scanning for devices...", .{});
    self.ensureDiscovery();
    if (self.discovery) |*disc| {
        disc.scan(1500) catch |err| {
            std.log.err("zobscast discovery error: {}", .{err});
        };
    }
    return true;
}

fn start(ctx: ?*anyopaque) callconv(.c) bool {
    std.log.info("zobscast start", .{});
    const self: *Output = @ptrCast(@alignCast(ctx.?));

    const io = self.threaded_io.io();
    if (self.connect_future) |*future| {
        _ = future.await(io);
        self.connect_future = null;
    }
    self.mutex.lock(io) catch return false;
    defer self.mutex.unlock(io);

    if (self.active) return true;

    ensureEncoder(self.ptr);

    const venc = c.obs_output_get_video_encoder(self.ptr);
    const aenc = c.obs_output_get_audio_encoder(self.ptr, 0);
    const act = c.obs_output_active(self.ptr);
    std.log.info("zobscast start check: ptr={?*} venc={?*} aenc={?*} active={}", .{ self.ptr, venc, aenc, act });

    // Check if output can begin capture and initialize encoders (must be done in start callback)
    if (!c.obs_output_can_begin_data_capture(self.ptr, 0)) {
        std.log.err("zobscast start: obs_output_can_begin_data_capture returned false (venc={?*} aenc={?*} active={})", .{ venc, aenc, act });
        return false;
    }
    if (!c.obs_output_initialize_encoders(self.ptr, 0)) {
        std.log.err("zobscast start: obs_output_initialize_encoders returned false", .{});
        return false;
    }

    self.connect_future = io.concurrent(connectTask, .{self}) catch |err| {
        std.log.err("zobscast: failed to spawn connect thread: {}", .{err});
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return false;
    };
    return true;
}

fn connectTask(self: *Output) void {
    const io = self.threaded_io.io();
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    // If sink_ip is still empty, try loading from saved settings
    if (self.sink_ip.len == 0) {
        const saved = loadSettings();
        if (saved) |s| {
            defer c.obs_data_release(s);
            self.applySettings(s);
        }
    }

    // Determine target IP and port
    var raw_target: []const u8 = self.sink_ip;
    var target_port: u16 = self.sink_port;

    if (raw_target.len == 0 and self.settings != null) {
        const s = c.obs_data_get_string(self.settings.?, "sink");
        if (s != null and s[0] != 0) {
            raw_target = std.mem.span(s);
        }
        const p = c.obs_data_get_int(self.settings.?, "port");
        if (p > 0 and p <= 65535) {
            target_port = @intCast(p);
        }
    }

    // Fallback: pick first discovered device if none chosen
    if (raw_target.len == 0) {
        self.ensureDiscovery();
        if (self.discovery) |*disc| {
            disc.scan(1000) catch {};
            disc.mutex.lockUncancelable(disc.io);
            if (disc.devices.items.len > 0) {
                raw_target = disc.devices.items[0].ip;
                target_port = disc.devices.items[0].port;
            }
            disc.mutex.unlock(disc.io);
        }
    }

    const parsed_target = parseTarget(raw_target, target_port);
    const target_ip = parsed_target.ip;
    target_port = parsed_target.port;

    if (target_ip.len == 0) {
        std.log.err("zobscast: no cast sink selected! Open Output properties to select or enter a device IP.", .{});
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_BAD_PATH);
        return;
    }

    std.log.info("zobscast start: casting to {s}:{d} (from setting '{s}')", .{ target_ip, target_port, raw_target });

    // 1. Ensure HTTP Server is running
    _ = self.ensureHttpServerUnlocked() catch |err| {
        std.log.err("zobscast: failed to start HTTP server: {}", .{err});
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };
    const server = self.server.?;

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
            std.log.info("zobscast: got video encoder extradata ({d} bytes)", .{extra_data_size});
            extradata_slice = extra_data_ptr[0..extra_data_size];
        } else {
            std.log.warn("zobscast: obs_encoder_get_extra_data for video returned no data", .{});
        }
    }

    const aenc = c.obs_output_get_audio_encoder(self.ptr, 0);
    var a_extra_ptr: [*c]u8 = null;
    var a_extra_size: usize = 0;
    var a_extradata_slice: ?[]const u8 = null;
    var audio_sample_rate: u32 = 0;
    var audio_channels: u32 = 0;

    if (aenc) |ae| {
        audio_sample_rate = c.obs_encoder_get_sample_rate(ae);
        if (c.obs_get_audio()) |a| {
            audio_channels = @intCast(c.audio_output_get_channels(a));
            if (audio_sample_rate == 0) {
                audio_sample_rate = c.audio_output_get_sample_rate(a);
            }
        }
        if (audio_channels == 0) audio_channels = 2;
        if (audio_sample_rate == 0) audio_sample_rate = 48000;

        if (c.obs_encoder_get_extra_data(ae, &a_extra_ptr, &a_extra_size) and a_extra_ptr != null and a_extra_size > 0) {
            std.log.info("zobscast: got audio encoder extradata ({d} bytes)", .{a_extra_size});
            a_extradata_slice = a_extra_ptr[0..a_extra_size];
        } else {
            std.log.warn("zobscast: obs_encoder_get_extra_data for audio returned no data", .{});
        }
    }

    if (!self.enable_video and !self.enable_audio) {
        std.log.err("zobscast: cannot start casting: both video and audio are disabled", .{});
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_BAD_PATH);
        return;
    }

    const muxer = Muxer.init(
        self.allocator,
        onMuxedData,
        self,
        self.enable_video,
        width,
        height,
        extradata_slice,
        self.enable_audio,
        audio_sample_rate,
        audio_channels,
        a_extradata_slice,
    ) catch |err| {
        std.log.err("zobscast: failed to initialize FFmpeg muxer: {}", .{err});
        server.clearClients();
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
        return;
    };
    self.muxer = muxer;

    // 3. Set initialization header
    server.setHeader(muxer.getHeader()) catch |err| {
        std.log.err("zobscast: failed to set HTTP stream header: {}", .{err});
        muxer.deinit();
        server.clearClients();
        self.muxer = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
        return;
    };

    // 4. Resolve local IP address facing destination
    var ip_buf: [64]u8 = undefined;
    const local_ip = server.getLocalIpFor(target_ip, target_port, &ip_buf) catch |err| {
        std.log.err("zobscast: failed to get local Ip For Client : {s} {}", .{ target_ip, err });
        muxer.deinit();
        server.clearClients();
        self.muxer = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };

    var url_buf: [256]u8 = undefined;
    const stream_url = std.mem.printSentinel(
        &url_buf,
        "http://{s}:{d}/live.mp4",
        .{ local_ip, server.port },
        0,
    ) catch "http://127.0.0.1:8010/live.mp4";
    std.log.info("zobscast: stream endpoint prepared at {s}", .{stream_url});

    // 5. Begin data capture (encoders already initialized in start())
    if (!c.obs_output_begin_data_capture(self.ptr, 0)) {
        std.log.err("zobscast: obs_output_begin_data_capture failed", .{});
        muxer.deinit();
        server.clearClients();
        self.muxer = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
        return;
    }

    // 6. Connect CastClient and request playback
    const cast_client = Client.init(
        self.allocator,
        target_ip,
        target_port,
        io,
    ) catch |err| {
        std.log.err("zobscast: failed to init Cast client: {}", .{err});
        c.obs_output_end_data_capture(self.ptr);
        muxer.deinit();
        server.clearClients();
        self.muxer = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };
    self.cast_client = cast_client;

    cast_client.startCast(stream_url) catch |err| {
        std.log.err("zobscast: failed to connect to Chromecast: {}", .{err});
        c.obs_output_end_data_capture(self.ptr);
        cast_client.deinit();
        muxer.deinit();
        server.clearClients();
        self.cast_client = null;
        self.muxer = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return;
    };

    self.active = true;
    std.log.info("zobscast stream live at {s}", .{stream_url});
    gui.setActive(true);
}

fn onMuxedData(ctx: ?*anyopaque, data: []const u8) void {
    if (ctx == null) return;
    const self: *Output = @ptrCast(@alignCast(ctx.?));
    if (self.server) |srv| {
        srv.broadcast(data);
    }
}

fn stop(ctx: ?*anyopaque, it: u64) callconv(.c) void {
    _ = it;
    std.log.info("zobscast stop", .{});
    const self: *Output = @ptrCast(@alignCast(ctx.?));
    const io = self.threaded_io.io();

    // Wait for any in-progress connection task before acquiring self.mutex.
    if (self.connect_future) |*future| {
        _ = future.await(io);
        self.connect_future = null;
    }

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.active) {
        c.obs_output_end_data_capture(self.ptr);
        self.active = false;
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
        srv.clearClients();
        srv.setHeader(&[_]u8{}) catch {};
    }

    self.deinitDiscovery();
    c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_SUCCESS);
}

fn get_data(ctx: ?*anyopaque, d: [*c]c.struct_encoder_packet) callconv(.c) void {
    const self: *Output = @ptrCast(@alignCast(ctx.?));
    if (!self.active or d == null or d.*.data == null or d.*.size == 0) {
        return;
    }

    const is_audio = (d.*.type == c.OBS_ENCODER_AUDIO);
    if (is_audio and !self.enable_audio) return;
    if (!is_audio and !self.enable_video) return;

    self.packet_count +%= 1;
    if (self.debug_logging and (self.packet_count % 120 == 0)) {
        std.log.info(
            "zobscast packet #{d}: type={s} size={d} pts={d} dts={d} keyframe={}",
            .{
                self.packet_count,
                if (is_audio) "audio" else "video",
                d.*.size,
                d.*.pts,
                d.*.dts,
                d.*.keyframe,
            },
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
            is_audio,
        ) catch |err| {
            std.log.err("zobscast muxer writePacket error: {}", .{err});
        };
    }
}
