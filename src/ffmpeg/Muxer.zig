const std = @import("std");
const av = @import("av");
const c = @import("c");

extern fn avformat_alloc_output_context2(
    ctx: *?*av.FormatContext,
    oformat: ?*const anyopaque,
    format_name: ?[*:0]const u8,
    filename: ?[*:0]const u8,
) c_int;
extern fn avformat_free_context(s: ?*av.FormatContext) void;
extern fn avformat_new_stream(s: *av.FormatContext, c: ?*anyopaque) ?*av.Stream;
extern fn avformat_write_header(s: *av.FormatContext, options: *?*anyopaque) c_int;
extern fn av_write_trailer(s: *av.FormatContext) c_int;
extern fn av_write_frame(s: *av.FormatContext, pkt: ?*av.Packet) c_int;
extern fn av_interleaved_write_frame(s: *av.FormatContext, pkt: ?*av.Packet) c_int;
extern fn avio_flush(s: *av.IOContext) void;

extern fn avio_alloc_context(
    buffer: [*]u8,
    buffer_size: c_int,
    write_flag: c_int,
    @"opaque": ?*anyopaque,
    read_packet: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) c_int,
    write_packet: ?*const fn (?*anyopaque, [*]const u8, c_int) callconv(.c) c_int,
    seek: ?*const fn (?*anyopaque, i64, c_int) callconv(.c) i64,
) ?*av.IOContext;
extern fn avio_context_free(s: *?*av.IOContext) void;

extern fn av_packet_alloc() ?*av.Packet;
extern fn av_packet_free(pkt: *?*av.Packet) void;
extern fn av_packet_unref(pkt: *av.Packet) void;

extern fn av_dict_set(
    pm: *?*anyopaque,
    key: [*:0]const u8,
    value: ?[*:0]const u8,
    flags: c_int,
) c_int;
extern fn av_dict_free(m: *?*anyopaque) void;
extern fn av_malloc(size: usize) ?[*]u8;
extern fn av_free(ptr: ?*anyopaque) void;
extern fn av_rescale_q(a: i64, b: av.Rational, c: av.Rational) i64;

pub const OnDataFn = *const fn (ctx: ?*anyopaque, data: []const u8) void;

pub const Muxer = struct {
    format_ctx: ?*av.FormatContext = null,
    avio_ctx: ?*av.IOContext = null,
    stream: ?*av.Stream = null,
    pkt: ?*av.Packet = null,
    avio_buffer: ?[*]u8 = null,
    on_data: OnDataFn,
    data_ctx: ?*anyopaque,
    header_data: std.ArrayListUnmanaged(u8) = .empty,

    header_done: bool = false,
    allocator: std.mem.Allocator,
    pts_offset: i64 = 0,
    has_pts_offset: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        on_data: OnDataFn,
        data_ctx: ?*anyopaque,
        width: u32,
        height: u32,
        extradata: ?[]const u8,
    ) !*Muxer {
        c.blog(c.LOG_INFO, "zobscast Muxer: initializing in-memory FFmpeg muxer (%ux%u)...", width, height);
        const self = try allocator.create(Muxer);
        self.* = .{
            .on_data = on_data,
            .data_ctx = data_ctx,
            .allocator = allocator,
        };

        const avio_buf_size: usize = 16 * 1024;
        self.avio_buffer = av_malloc(avio_buf_size) orelse {
            c.blog(c.LOG_ERROR, "zobscast Muxer: av_malloc failed");
            return error.OutOfMemory;
        };

        self.avio_ctx = avio_alloc_context(
            self.avio_buffer.?,
            @intCast(avio_buf_size),
            1, // writeable
            @ptrCast(self),
            null,
            writePacketCb,
            null,
        ) orelse {
            c.blog(c.LOG_ERROR, "zobscast Muxer: avio_alloc_context failed");
            return error.AvioAllocFailed;
        };

        var fmt_ctx: ?*av.FormatContext = null;
        if (avformat_alloc_output_context2(&fmt_ctx, null, "mp4", null) < 0 or fmt_ctx == null) {
            c.blog(c.LOG_ERROR, "zobscast Muxer: avformat_alloc_output_context2 failed");
            return error.AvformatAllocFailed;
        }
        self.format_ctx = fmt_ctx;
        self.format_ctx.?.pb = self.avio_ctx;

        self.stream = avformat_new_stream(self.format_ctx.?, null) orelse {
            c.blog(c.LOG_ERROR, "zobscast Muxer: avformat_new_stream failed");
            return error.NewStreamFailed;
        };

        self.stream.?.codecpar.codec_type = .VIDEO;
        self.stream.?.codecpar.codec_id = .H264;
        self.stream.?.codecpar.width = @intCast(width);
        self.stream.?.codecpar.height = @intCast(height);
        self.stream.?.time_base = .{ .num = 1, .den = 1000 };

        if (extradata) |extra| {
            if (extra.len > 0) {
                const extra_buf = av_malloc(extra.len + 64) orelse return error.OutOfMemory;
                @memcpy(extra_buf[0..extra.len], extra);
                @memset(extra_buf[extra.len .. extra.len + 64], 0);
                self.stream.?.codecpar.extradata = extra_buf;
                self.stream.?.codecpar.extradata_size = @intCast(extra.len);
                c.blog(c.LOG_INFO, "zobscast Muxer: set codecpar.extradata (%u bytes)", @as(c_uint, @intCast(extra.len)));
            }
        }

        var opts: ?*anyopaque = null;
        _ = av_dict_set(&opts, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0);
        _ = av_dict_set(&opts, "brand", "iso6", 0);

        const write_ret = avformat_write_header(self.format_ctx.?, &opts);
        if (write_ret < 0) {
            av_dict_free(&opts);
            c.blog(c.LOG_ERROR, "zobscast Muxer: avformat_write_header failed with code %d", write_ret);
            return error.WriteHeaderFailed;
        }
        av_dict_free(&opts);

        self.pkt = av_packet_alloc() orelse return error.OutOfMemory;
        self.header_done = true;
        c.blog(c.LOG_INFO, "zobscast Muxer: initialized successfully (header size: %u bytes)", @as(c_uint, @intCast(self.header_data.items.len)));
        return self;
    }

    fn writePacketCb(user_data: ?*anyopaque, buf: [*]const u8, buf_size: c_int) callconv(.c) c_int {
        if (user_data == null or buf_size <= 0) return 0;
        const self: *Muxer = @ptrCast(@alignCast(user_data.?));

        const slice = buf[0..@intCast(buf_size)];

        if (!self.header_done) {
            self.header_data.appendSlice(self.allocator, slice) catch {};
        }

        self.on_data(self.data_ctx, slice);
        return buf_size;
    }

    pub fn writePacket(
        self: *Muxer,
        data: [*]const u8,
        size: usize,
        pts: i64,
        dts: i64,
        keyframe: bool,
        timebase_num: i32,
        timebase_den: i32,
    ) !void {
        if (self.pkt) |pkt| {
            av_packet_unref(pkt);
            pkt.data = @constCast(data);
            pkt.size = @intCast(size);
            pkt.stream_index = 0;
            if (keyframe) {
                pkt.flags |= 1; // AV_PKT_FLAG_KEY
            } else {
                pkt.flags &= ~@as(c_int, 1);
            }

            if (!self.has_pts_offset) {
                self.pts_offset = dts;
                self.has_pts_offset = true;
            }

            const in_tb: av.Rational = if (timebase_num > 0 and timebase_den > 0)
                .{ .num = timebase_num, .den = timebase_den }
            else
                .{ .num = 1, .den = 30 };
            const out_tb = self.stream.?.time_base;

            pkt.pts = av_rescale_q(pts - self.pts_offset, in_tb, out_tb);
            pkt.dts = av_rescale_q(dts - self.pts_offset, in_tb, out_tb);
            pkt.duration = av_rescale_q(1, in_tb, out_tb);

            const ret = av_write_frame(self.format_ctx.?, pkt);
            if (ret < 0) {
                c.blog(c.LOG_ERROR, "zobscast Muxer: av_write_frame error: %d", ret);
                return error.WriteFrameFailed;
            }
            if (self.avio_ctx) |pb| {
                avio_flush(pb);
            }
        }
    }

    pub fn getHeader(self: *Muxer) []const u8 {
        return self.header_data.items;
    }

    pub fn deinit(self: *Muxer) void {
        c.blog(c.LOG_INFO, "zobscast Muxer: cleaning up...");
        if (self.format_ctx) |ctx| {
            _ = av_write_trailer(ctx);
        }
        if (self.pkt != null) {
            av_packet_free(&self.pkt);
        }

        if (self.avio_ctx != null) {
            avio_context_free(&self.avio_ctx);
        }

        if (self.format_ctx) |ctx| {
            avformat_free_context(ctx);
        }
        if (self.avio_buffer) |buf| {
            av_free(buf);
        }
        self.header_data.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
