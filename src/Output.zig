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
mutex: std.atomic.Mutex = .unlocked,
allocator: std.mem.Allocator,

var global_discovery: ?*Discovery = null;
var discovery_mutex: std.atomic.Mutex = .unlocked;

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

pub fn toggle(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast toggle");
    const output = c.obs_get_output_by_name(info.id);
    if (output) |out| {
        defer c.obs_output_release(out);
        if (c.obs_output_active(out)) {
            c.obs_output_stop(out);
        } else {
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

    const encoder_settings = c.obs_data_create();
    defer c.obs_data_release(encoder_settings);
    c.obs_data_set_bool(encoder_settings, "use_bufsize", true);

    const rate_control = c.obs_data_get_string(settings, "rate_control");
    c.obs_data_set_string(encoder_settings, "rate_control", if (rate_control != null and rate_control[0] != 0) rate_control else "CRF");
    c.obs_data_set_string(encoder_settings, "profile", "high");

    const preset = c.obs_data_get_string(settings, "preset");
    c.obs_data_set_string(encoder_settings, "preset", if (preset != null and preset[0] != 0) preset else "ultrafast");

    const bitrate = c.obs_data_get_int(settings, "bitrate");
    const br: i64 = if (bitrate > 0) bitrate else 2500;
    c.obs_data_set_int(encoder_settings, "bitrate", br);
    c.obs_data_set_int(encoder_settings, "buffer_size", br);

    const encoder = c.obs_video_encoder_create("obs_x264", "zobscast_x264", encoder_settings, null);
    if (encoder) |enc| {
        c.obs_encoder_set_video(enc, c.obs_get_video());
        c.obs_encoder_set_preferred_video_format(enc, c.VIDEO_FORMAT_NV12);
        c.obs_output_set_video_encoder(output, enc);
        c.obs_encoder_release(enc);
    }

    const started = c.obs_output_start(output);
    var encoding: bool = false;
    var capturing: bool = false;
    if (started) {
        encoding = c.obs_output_initialize_encoders(output, 0);
        if (!c.obs_output_can_begin_data_capture(output, 0)) {
            c.blog(c.LOG_ERROR, "zobscast cannot begin data capture");
            return;
        }
        capturing = c.obs_output_begin_data_capture(output, 0);
    }
    c.blog(c.LOG_INFO, "zobscast autostart: started=%d encoding=%d capturing=%d", started, encoding, capturing);
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
}

pub fn get_properties(ctx: ?*anyopaque) callconv(.c) ?*c.obs_properties_t {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast get_properties");
    const props = c.obs_properties_create();

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

    // If sink_ip is still empty, try loading from saved settings
    if (self.sink_ip.len == 0) {
        const saved = loadSettings();
        if (saved) |s| {
            defer c.obs_data_release(s);
            self.applySettings(s);
        }
    }

    // Determine target IP
    var target_ip: []const u8 = self.sink_ip;
    if (target_ip.len == 0 and self.settings != null) {
        const s = c.obs_data_get_string(self.settings.?, "sink");
        if (s != null and s[0] != 0) {
            target_ip = std.mem.span(s);
        }
    }

    // Fallback: pick first discovered device if none chosen
    if (target_ip.len == 0) {
        ensureDiscovery();
        if (global_discovery) |disc| {
            disc.scan(1000) catch {};
            while (!disc.mutex.tryLock()) {
                std.Thread.yield() catch {};
            }
            if (disc.devices.items.len > 0) {
                target_ip = disc.devices.items[0].ip;
            }
            disc.mutex.unlock();
        }
    }

    if (target_ip.len == 0) {
        c.blog(c.LOG_ERROR, "zobscast: no cast sink selected! Open Output properties to select or enter a device IP.");
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_BAD_PATH);
        return false;
    }

    c.blog(c.LOG_INFO, "zobscast casting to destination: %s", target_ip.ptr);

    // 1. Start HTTP Server
    const server = Server.init(self.allocator) catch {
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return false;
    };
    self.server = server;
    _ = server.start(8010) catch {
        server.deinit();
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return false;
    };

    // 2. Initialize FFmpeg Muxer
    const muxer = Muxer.init(self.allocator, onMuxedData, self) catch {
        server.deinit();
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
        return false;
    };
    self.muxer = muxer;

    // 3. Set initialization header
    server.setHeader(muxer.getHeader());

    // 4. Resolve local IP address facing destination
    var ip_buf: [64]u8 = undefined;
    const local_ip = Server.getLocalIpFor(target_ip, &ip_buf) catch "127.0.0.1";

    var url_buf: [256]u8 = undefined;
    const stream_url = std.fmt.bufPrintZ(&url_buf, "http://{s}:{u}/live.mp4", .{ local_ip, server.port }) catch "http://127.0.0.1:8010/live.mp4";

    // 5. Connect CastClient and request playback
    const cast_client = CastClient.init(self.allocator, target_ip, 8009) catch {
        muxer.deinit();
        server.deinit();
        self.muxer = null;
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return false;
    };
    self.cast_client = cast_client;

    cast_client.startCast(stream_url) catch |err| {
        c.blog(c.LOG_ERROR, "zobscast failed to connect to Chromecast: %s", @errorName(err).ptr);
        cast_client.deinit();
        muxer.deinit();
        server.deinit();
        self.cast_client = null;
        self.muxer = null;
        self.server = null;
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_CONNECT_FAILED);
        return false;
    };

    self.active = true;
    c.blog(c.LOG_INFO, "zobscast stream live at %s", stream_url.ptr);
    return true;
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

    while (!self.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer self.mutex.unlock();

    if (self.active) {
        c.obs_output_end_data_capture(self.ptr);
        self.active = false;
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
    if (!self.active or d == null) {
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
        return;
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
