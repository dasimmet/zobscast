const c = @import("c");
const std = @import("std");

pub const info = c.obs_source_info{
    .id = "zobscast",
    .type = c.OBS_SOURCE_TYPE_INPUT,
    .output_flags = c.OBS_SOURCE_VIDEO,
    .get_name = get_name,
    .get_width = width,
    .get_height = height,
};

fn get_name(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast input getname");
    return "zobscast";
}

fn width(ctx: ?*anyopaque) callconv(.c) u32 {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast input width");
    return 100;
}

fn height(ctx: ?*anyopaque) callconv(.c) u32 {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast input height");
    return 100;
}
