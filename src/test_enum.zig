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

pub fn cleanIp(input: []const u8) []const u8 {
    var s = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, s, '(')) |open_idx| {
        if (std.mem.indexOfScalarPos(u8, s, open_idx, ')')) |close_idx| {
            s = std.mem.trim(u8, s[open_idx + 1 .. close_idx], " \t\r\n");
        }
    }
    if (std.mem.indexOfScalar(u8, s, ':')) |colon_idx| {
        s = s[0..colon_idx];
    }
    return s;
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

test "cleanIp extraction" {
    const testing = std.testing;
    try testing.expectEqualStrings("192.168.132.217", cleanIp("Xiaomi TV Box (192.168.132.217)"));
    try testing.expectEqualStrings("192.168.132.217", cleanIp("Xiaomi TV Box (192.168.132.217:8009)"));
    try testing.expectEqualStrings("192.168.132.217", cleanIp("192.168.132.217"));
    try testing.expectEqualStrings("192.168.132.217", cleanIp(" 192.168.132.217:8009 "));
}

test "check std.json" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Msg = struct {
        type: []const u8,
        requestId: ?u32 = null,
    };

    const str = try std.json.Stringify.valueAlloc(allocator, Msg{ .type = "CONNECT" }, .{ .emit_null_optional_fields = false });
    defer allocator.free(str);
    try testing.expectEqualStrings("{\"type\":\"CONNECT\"}", str);

    const parsed = try std.json.parseFromSlice(Msg, allocator, str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("CONNECT", parsed.value.type);
}

test "parse receiver status json" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample =
        \\{"requestId":1,"status":{"applications":[{"appId":"CC1AD845","appType":"WEB","displayName":"Default Media Receiver","iconUrl":"","isIdleScreen":false,"launchedFromCloud":false,"namespaces":[{"name":"urn:x-cast:com.google.cast.media"}],"sessionId":"session-123","statusText":"Default Media Receiver","transportId":"67c54b3c-f5d7-4935-b467-290cda2539f6"}]}}
    ;

    const Application = struct {
        appId: ?[]const u8 = null,
        sessionId: ?[]const u8 = null,
        transportId: ?[]const u8 = null,
    };
    const ReceiverStatus = struct {
        applications: ?[]const Application = null,
    };
    const ReceiverResponse = struct {
        requestId: ?i64 = null,
        status: ?ReceiverStatus = null,
    };

    const parsed = try std.json.parseFromSlice(ReceiverResponse, allocator, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testing.expect(parsed.value.status != null);
    try testing.expect(parsed.value.status.?.applications != null);
    const apps = parsed.value.status.?.applications.?;
    try testing.expectEqual(@as(usize, 1), apps.len);
    try testing.expectEqualStrings("CC1AD845", apps[0].appId.?);
    try testing.expectEqualStrings("session-123", apps[0].sessionId.?);
    try testing.expectEqualStrings("67c54b3c-f5d7-4935-b467-290cda2539f6", apps[0].transportId.?);

    // Dynamic parsing with Value
    const val_parsed = try std.json.parseFromSlice(std.json.Value, allocator, sample, .{});
    defer val_parsed.deinit();
    try testing.expect(val_parsed.value == .object);
}
