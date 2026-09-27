const c = @import("c");
const std = @import("std");
const Output = @import("Output.zig");
const Source = @import("Source.zig");

const ObsFrontendEvent = CTranslateEnum(c, c_int, "OBS_FRONTEND_EVENT_");

var options_source: ?*c.obs_source_t = null;

export fn obs_module_load() callconv(.c) bool {
    c.blog(c.LOG_INFO, "zobscast module_load");
    c.blog(c.LOG_INFO, "zobscast obs_register_output");
    c.obs_register_output(&Output.info);
    c.blog(c.LOG_INFO, "zobscast obs_register_source");
    c.obs_register_source(&Source.info);
    c.blog(c.LOG_INFO, "zobscast obs_frontend_add_event_callback");
    c.obs_frontend_add_event_callback(OBSEvent, null);
    return true;
}

export fn obs_module_unload() callconv(.c) void {
    c.blog(c.LOG_INFO, "zobscast module_unload");

    if (options_source) |s| {
        c.obs_source_release(s);
        options_source = null;
    }

    const output = c.obs_get_output_by_name(Output.info.id);
    if (output) |out| {
        if (c.obs_output_active(out)) {
            c.obs_output_stop(out);
        }
        c.obs_output_release(out);
    }

    Output.deinitDiscovery();
}

pub fn openOptions(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    c.blog(c.LOG_INFO, "zobscast openOptions");
    if (options_source == null) {
        const saved_settings = Output.loadSettings();
        const settings = saved_settings orelse c.obs_data_create();
        defer c.obs_data_release(settings);
        Output.get_defaults(settings);
        options_source = c.obs_source_create_private(Source.info.id, "Zobscast Settings", settings);
    }
    if (options_source) |s| {
        c.obs_frontend_open_source_properties(s);
    }
}

fn OBSEvent(ev: c_uint, ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    const evt: ObsFrontendEvent = @enumFromInt(ev);
    c.blog(c.LOG_INFO, "zobscast frontend event: %u %s", ev, @tagName(evt).ptr);
    switch (evt) {
        .FINISHED_LOADING => {
            const gui = @import("gui.zig");
            const toggle_local: [*c]const u8 = obs_module_text("Zobscast.Toggle");
            gui.addToggleAction(toggle_local, Output.toggle, null);
            const options_local: [*c]const u8 = obs_module_text("Zobscast.Options");
            c.obs_frontend_add_tools_menu_item(options_local, openOptions, null);
        },
        else => {},
    }
}

var obs_module_pointer: *c.obs_module_t = undefined;
pub export fn obs_module_set_pointer(module: *c.obs_module_t) void {
    obs_module_pointer = module;
}

pub export fn obs_current_module() *c.obs_module_t {
    return obs_module_pointer;
}

export fn obs_module_ver() callconv(.c) c_uint {
    return c.LIBOBS_API_VER;
}

var obs_module_lookup: ?*c.lookup_t = null;
export fn obs_module_set_locale(locale: [*c]const u8) callconv(.c) void {
    if (obs_module_lookup) |lookup|
        c.text_lookup_destroy(lookup);
    obs_module_lookup = c.obs_module_load_locale(obs_current_module(), "en-US", locale);
}

export fn obs_module_free_locale() callconv(.c) void {
    c.text_lookup_destroy(obs_module_lookup);
    obs_module_lookup = null;
}

fn obs_module_text(val: [*c]const u8) callconv(.c) [*c]const u8 {
    var out: [*c]const u8 = val;
    _ = c.text_lookup_getstr(obs_module_lookup, val, &out);
    return out;
}

// Generates an enum from all decls prefixed with 'decl_prefix'
fn CTranslateEnum(comptime c_struct: type, comptime inttype: type, comptime decl_prefix: []const u8) type {
    const c_struct_decls = comptime std.meta.declarations(c_struct);
    @setEvalBranchQuota(c_struct_decls.len * 10);
    comptime var field_count: usize = 0;
    inline for (c_struct_decls) |decl| {
        const decl_name = if (@typeInfo(@TypeOf(decl)) == .@"struct" and @hasField(@TypeOf(decl), "name")) decl.name else decl;
        if (std.mem.startsWith(u8, decl_name, decl_prefix) and (@TypeOf(@field(c_struct, decl_name)) == inttype)) {
            field_count += 1;
        }
    }
    comptime var names: [field_count][]const u8 = undefined;
    comptime var values: [field_count]inttype = undefined;
    var idx: usize = 0;
    inline for (c_struct_decls) |decl| {
        const decl_name = if (@typeInfo(@TypeOf(decl)) == .@"struct" and @hasField(@TypeOf(decl), "name")) decl.name else decl;
        if (std.mem.startsWith(u8, decl_name, decl_prefix) and (@TypeOf(@field(c_struct, decl_name)) == inttype)) {
            names[idx] = decl_name[decl_prefix.len..];
            values[idx] = @field(c_struct, decl_name);
            idx += 1;
        }
    }
    return @Enum(inttype, .nonexhaustive, &names, &values);
}

test "CTranslateEnum" {
    const testing = std.testing;
    const Dummy = struct {
        pub const TEST_EVT_A: c_int = 0;
        pub const TEST_EVT_B: c_int = 1;
        pub const OTHER_VAL: c_int = 2;
    };
    const TestEnum = CTranslateEnum(Dummy, c_int, "TEST_EVT_");
    const val_a: TestEnum = @enumFromInt(0);
    const val_b: TestEnum = @enumFromInt(1);
    try testing.expectEqualStrings("A", @tagName(val_a));
    try testing.expectEqualStrings("B", @tagName(val_b));
}
