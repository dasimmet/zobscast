const c = @import("c");
const std = @import("std");

pub const info = c.obs_output_info{
    .id = "zobscast",
    .flags = c.OBS_OUTPUT_VIDEO,
    .get_name = name,
    .create = create,
    .destroy = destroy,
    .start = start,
    .stop = stop,
    .encoded_packet = data,
    .get_total_bytes = total_bytes,
    // .encoded_video_codecs = "h264",
    // .encoded_audio_codecs = "aac",
    .raw_video = raw_video,
};

fn name(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast get_name");
    return "zobscast";
}

fn create(ctx: ?*c.struct_obs_data, ptr: ?*c.struct_obs_output) callconv(.c) ?*anyopaque {
    _ = ctx;
    _ = ptr;
    c.blog(c.LOG_INFO, "zobscast create");
    return null;
}
fn destroy(ctx: ?*anyopaque) callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast destroy");
    _ = ctx;
}

fn start(ctx: ?*anyopaque) callconv(.c) bool {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast start");
    return true;
}

fn stop(ctx: ?*anyopaque, it: u64) callconv(.c) void {
    _ = ctx;
    _ = it;
}

fn data(ctx: ?*anyopaque, d: [*c]c.struct_encoder_packet) callconv(.c) void {
    _ = ctx;
    _ = d;
}

fn total_bytes(ctx: ?*anyopaque) callconv(.c) u64 {
    _ = ctx;
    return 0;
}

fn raw_video(ctx: ?*anyopaque, d: [*c]c.struct_video_data) callconv(.c) void {
    _ = ctx;
    _ = d;
}
