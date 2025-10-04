const c = @import("c");
const std = @import("std");

ptr: *c.obs_output_t,
gpa_impl: std.heap.GeneralPurposeAllocator(.{}),
gpa: std.mem.Allocator,
active: bool = false,
log_timestamp: usize = 0,
proc: ?std.process.Child = null,
fifo: ?std.fs.File = null,
mutex: std.Thread.Mutex = .{},

pub const info: c.obs_output_info = .{
    .id = "zobscast",
    .flags = c.OBS_OUTPUT_VIDEO | c.OBS_OUTPUT_ENCODED,
    .get_name = name,
    .create = create,
    .destroy = destroy,
    .start = start,
    .stop = stop,
    .encoded_packet = get_data,
    // .get_total_bytes = total_bytes,
    .encoded_video_codecs = "h264",
    // .encoded_audio_codecs = "",
    // .raw_video = raw_video,
};

var instance: ?*@This() = null;

pub fn toggle(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    if (instance) |inst| {
        c.obs_output_signal_stop(inst.ptr, c.OBS_OUTPUT_SUCCESS);
    } else {
        autostart() catch @panic("zobscast toggle");
    }
}

pub fn autostart() !void {
    const output = c.obs_output_create(info.id, info.id, null, null);

    const settings = c.obs_data_create();
    defer c.obs_data_release(settings);
    c.obs_data_set_bool(settings, "use_bufsize", true);
    c.obs_data_set_string(settings, "rate_control", "CRF");
    c.obs_data_set_string(settings, "profile", "high");
    c.obs_data_set_string(settings, "preset", "ultrafast");
    c.obs_data_set_int(settings, "bitrate", 1000);
    c.obs_data_set_int(settings, "buffer_size", 1000);
    const encoder = c.obs_video_encoder_create("obs_x264", "test_x264", settings, null);
    c.obs_encoder_set_video(encoder, c.obs_get_video());

    c.obs_encoder_set_preferred_video_format(encoder, c.VIDEO_FORMAT_YUVA);
    c.obs_output_set_video_encoder(output, encoder);
    const started = c.obs_output_start(output);
    var encoding: bool = false;
    var capturing: bool = false;
    if (started) {
        encoding = c.obs_output_initialize_encoders(output, 0);
        if (!c.obs_output_can_begin_data_capture(output, 0)) {
            c.blog(c.LOG_ERROR, "zobscast cannot begin: %d %d %d", started, encoding, capturing);
            return;
        }
        capturing = c.obs_output_begin_data_capture(output, 0);
    }
    c.blog(c.LOG_INFO, "zobscast autostart: %d %d %d", started, encoding, capturing);
}

fn name(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast get_name");
    return "zobscast";
}

fn create(ctx: ?*c.struct_obs_data, ptr: ?*c.struct_obs_output) callconv(.c) ?*anyopaque {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast create");
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const self = gpa.allocator().create(@This()) catch @panic("zobscast create alloc error");
    self.* = .{
        .gpa_impl = gpa,
        .gpa = undefined,
        .active = false,
        .ptr = ptr.?,
    };
    self.gpa = self.gpa_impl.allocator();

    _ = std.process.Child.run(.{
        .allocator = self.gpa,
        .argv = &.{ "rm", "-f", "/tmp/mkchromecast.fifo.mp4" },
    }) catch @panic("rmfifo");
    _ = std.process.Child.run(.{
        .allocator = self.gpa,
        .argv = &.{ "mkfifo", "/tmp/mkchromecast.fifo.mp4" },
    }) catch @panic("mkfifo");

    self.proc = .init(&.{
        "mkchromecast",
        "--debug",
        "--video",
        "--command",
        \\ffmpeg -i /tmp/mkchromecast.fifo.mp4 -c:v copy
        \\-fflags nobuffer -vcodec libx264 -r 24 -preset superfast -pix_fmt yuv420p -g 6
        \\-f mp4
        \\-movflags frag_keyframe+empty_moov
        \\pipe:1
        // \\-max_muxing_queue_size 9999
        // \\-pix_fmt yuv420p
    }, self.gpa);
    self.proc.?.spawn() catch @panic("mkchromecast spawn");
    instance = self;
    return self;
}

fn destroy(ctx: ?*anyopaque) callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast destroy");
    const self: *@This() = @ptrCast(@alignCast(ctx.?));

    var alloc = self.gpa_impl;
    alloc.allocator().destroy(self);
    _ = alloc.deinit();
}

fn start(ctx: ?*anyopaque) callconv(.c) bool {
    c.blog(c.LOG_INFO, "zobscast start");
    const self: *@This() = @ptrCast(@alignCast(ctx.?));
    self.active = true;
    return self.active;
}

fn stop(ctx: ?*anyopaque, it: u64) callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast stop: %d", it);
    const self: *@This() = @ptrCast(@alignCast(ctx.?));

    if (self.active) {
        c.obs_output_end_data_capture(self.ptr);
        self.active = false;
    }

    if (self.fifo) |fifo| {
        fifo.close();
        _ = std.process.Child.run(.{
            .allocator = self.gpa,
            .argv = &.{ "rm", "-f", "/tmp/mkchromecast.fifo.mp4" },
        }) catch {};
        self.fifo = null;
    }

    if (self.proc) |*proc| {
        std.posix.kill(proc.id, std.posix.SIG.KILL) catch {};
        self.proc = null;
    }
}

fn get_data(ctx: ?*anyopaque, d: [*c]c.struct_encoder_packet) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(ctx.?));
    if (d == null) {
        c.obs_output_signal_stop(self.ptr, c.OBS_OUTPUT_ENCODE_ERROR);
    }
    // c.blog(
    //     c.LOG_INFO,
    //     "zobscast get_data %u %u",
    //     d.*.timebase_num,
    //     d.*.size,
    // );

    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.fifo == null) {
        self.fifo = std.fs.cwd().openFile("/tmp/mkchromecast.fifo.mp4", .{
            .mode = .write_only,
            .lock = .exclusive,
        }) catch @panic("open");
    }

    self.fifo.?.writeAll(d.*.data[0..d.*.size]) catch @panic("fifo write");
}
