const c = @import("c");
const std = @import("std");

pub const info = c.obs_source_info{
    .id = "zobscast",
    .type = c.OBS_SOURCE_TYPE_INPUT,
    .output_flags = c.OBS_SOURCE_VIDEO,
    .get_name = get_name,
    .create = create,
    .destroy = destroy,
    .get_width = width,
    .get_height = height,
    .update = update,
};

fn get_name(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = ctx;
    return "Zobscast";
}

fn create(settings: ?*c.obs_data_t, source: ?*c.obs_source_t) callconv(.c) ?*anyopaque {
    _ = source;
    c.blog(c.LOG_INFO, "zobscast source create");
    if (settings) |s| {
        update(null, s);
    }
    return @ptrFromInt(1);
}

fn destroy(data: ?*anyopaque) callconv(.c) void {
    _ = data;
    c.blog(c.LOG_INFO, "zobscast source destroy");
}

fn update(data: ?*anyopaque, settings: ?*c.obs_data_t) callconv(.c) void {
    _ = data;
    _ = settings;
    c.blog(c.LOG_INFO, "zobscast source update");
}

fn width(ctx: ?*anyopaque) callconv(.c) u32 {
    _ = ctx;
    return 1920;
}

fn height(ctx: ?*anyopaque) callconv(.c) u32 {
    _ = ctx;
    return 1080;
}
