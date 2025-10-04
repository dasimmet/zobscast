const c = @import("c");
const std = @import("std");

gpa_impl: std.heap.GeneralPurposeAllocator(.{}),
gpa: std.mem.Allocator,
active: bool = false,
log_timestamp: usize = 0,
ptr: *c.obs_output_t,

pub const info: c.obs_output_info = .{
    .id = "zobscast",
    .flags = c.OBS_OUTPUT_VIDEO,
    .get_name = name,
    .create = create,
    .destroy = destroy,
    .start = start,
    .stop = stop,
    // .encoded_packet = data,
    // .get_total_bytes = total_bytes,
    // .encoded_video_codecs = "h264",
    // .encoded_audio_codecs = "aac",
    .raw_video = raw_video,
};

pub fn autostart() !void {
    const output = c.obs_output_create(info.id, info.id, null, null);
    const vid = c.obs_get_video();
    c.obs_output_set_media(output, vid, null);
    const started = c.obs_output_start(output);
    var capturing: bool = false;
    if (started) {
        capturing = c.obs_output_begin_data_capture(output, 0);
    }
    c.blog(c.LOG_INFO, "zobscast autostart: %d %d", started, capturing);
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
    return self;
}

fn destroy(ctx: ?*anyopaque) callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast destroy");
    const self: *@This() = @ptrCast(@alignCast(ctx.?));
    self.gpa.destroy(self);
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
}

// fn data(ctx: ?*anyopaque, d: [*c]c.struct_encoder_packet) callconv(.c) void {
//     c.blog(c.LOG_INFO, "zobscast data");
//     _ = ctx;
//     _ = d;
// }

// fn total_bytes(ctx: ?*anyopaque) callconv(.c) u64 {
//     _ = ctx;
//     return 0;
// }

fn raw_video(ctx: ?*anyopaque, d: [*c]c.struct_video_data) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(ctx.?));
    const time: usize = @intCast(d.*.timestamp);
    if (time - self.log_timestamp > 10000) {
        self.log_timestamp = time;
        c.blog(
            c.LOG_INFO,
            "zobscast raw_video %d",
            time,
        );
    }
}
