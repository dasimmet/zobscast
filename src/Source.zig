const c = @import("c");
const std = @import("std");

pub const info = c.struct_obs_source_info{
    .id = "zobscast",
    .type = c.OBS_SOURCE_TYPE_INPUT,
    .output_flags = c.OBS_SOURCE_VIDEO,
    .get_name = get_name,
    .get_width = my_width,
    .get_height = my_height,
};

fn get_name(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = ctx;
    std.log.info("get_name", .{});
    std.log.info("get_name", .{});
    std.log.info("get_name", .{});
    std.log.info("get_name", .{});
    std.log.info("get_name", .{});
    std.log.info("get_name", .{});
    std.log.info("get_name", .{});
    return "zobscast";
}

fn my_width(ctx: ?*anyopaque) callconv(.c) u32 {
    _ = ctx;
    std.log.info("get_width", .{});
    return 100;
}

fn my_height(ctx: ?*anyopaque) callconv(.c) u32 {
    _ = ctx;
    std.log.info("get_height", .{});
    return 100;
}
