const std = @import("std");

pub fn CTranslateEnum(comptime c_struct: type, comptime inttype: type, comptime decl_prefix: []const u8) type {
    const c_struct_decls = comptime std.meta.declarations(c_struct);
    @setEvalBranchQuota(c_struct_decls.len * 10);
    comptime var field_count: usize = 0;
    inline for (c_struct_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, decl_prefix) and (@TypeOf(@field(c_struct, decl.name)) == inttype)) {
            field_count += 1;
        }
    }
    comptime var names: [field_count][]const u8 = undefined;
    comptime var values: [field_count]inttype = undefined;
    var idx: usize = 0;
    inline for (c_struct_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, decl_prefix) and (@TypeOf(@field(c_struct, decl.name)) == inttype)) {
            names[idx] = decl.name[decl_prefix.len..];
            values[idx] = @field(c_struct, decl.name);
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
