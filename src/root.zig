const c = @import("c");
const std = @import("std");
const Output = @import("Output.zig");
const Source = @import("Source.zig");

export fn obs_module_load() callconv(.c) bool {
    c.obs_register_output(&Output.info);
    c.obs_register_source(&Source.info);
    return true;
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
