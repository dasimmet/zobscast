const c = @import("c");
const std = @import("std");
const Output = @import("Output.zig");
const Source = @import("Source.zig");

const ObsFrontendEvent = CTranslateEnum(c, c_int, "OBS_FRONTEND_EVENT_");

export fn obs_module_load() callconv(.c) bool {
    c.blog(c.LOG_INFO, "zobscast module_load");
    c.obs_register_output(&Output.info);
    c.obs_register_source(&Source.info);
    c.obs_frontend_add_event_callback(OBSEvent, null);
    return true;
}

export fn obs_module_unload() callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast module_unload");
    c.obs_frontend_remove_event_callback(OBSEvent, null);
}

fn OBSEvent(ev: c_uint, ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    const evt: ObsFrontendEvent = @enumFromInt(ev);
    c.blog(c.LOG_INFO, "zobscast frontend event: %d %s", ev, @tagName(evt).ptr);
    switch (evt) {
        .FINISHED_LOADING => {
            c.obs_frontend_add_tools_menu_item("toggle zobscast output", Output.toggle, null);
        },
        else => {},
    }
}

var obs_module_pointer: *c.obs_module_t = undefined;
export fn obs_module_set_pointer(module: *c.obs_module_t) void {
    obs_module_pointer = module;
}

export fn obs_current_module() *c.obs_module_t {
    return obs_module_pointer;
}

export fn obs_module_ver() callconv(.c) c_uint {
    return c.LIBOBS_API_VER;
}

// Generates an enum from all decls prefixed with 'decl_prefix'
fn CTranslateEnum(comptime c_struct: type, comptime inttype: type, comptime decl_prefix: []const u8) type {
    const c_struct_decls = comptime std.meta.declarations(c_struct);
    @setEvalBranchQuota(c_struct_decls.len * 10);
    comptime var field_count: usize = 0;
    inline for (c_struct_decls) |decl| {
        if (std.mem.startsWith(
            u8,
            decl.name,
            decl_prefix,
        ) and (@TypeOf(@field(c_struct, decl.name)) == inttype)) {
            field_count += 1;
        }
    }
    comptime var fields: [field_count]std.builtin.Type.EnumField = undefined;
    field_count = 0;
    inline for (c_struct_decls) |decl| {
        if (std.mem.startsWith(
            u8,
            decl.name,
            decl_prefix,
        ) and (@TypeOf(@field(c_struct, decl.name)) == inttype)) {
            fields[field_count] = .{
                .name = decl.name[decl_prefix.len..],
                .value = @field(c_struct, decl.name),
            };
            field_count += 1;
        }
    }
    return @Type(std.builtin.Type{
        .@"enum" = .{
            .is_exhaustive = false,
            .tag_type = inttype,
            .fields = &fields,
            .decls = &.{},
        },
    });
}
