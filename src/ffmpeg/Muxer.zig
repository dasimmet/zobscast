const std = @import("std");

pub const AVRational = extern struct {
    num: c_int,
    den: c_int,
};

pub const AVCodecParameters = extern struct {
    codec_type: c_int,
    codec_id: c_uint,
    codec_tag: u32,
    extradata: ?[*]u8,
    extradata_size: c_int,
    format: c_int,
    bit_rate: i64,
    bits_per_coded_sample: c_int,
    bits_per_raw_sample: c_int,
    profile: c_int,
    level: c_int,
    width: c_int,
    height: c_int,
};

pub const AVStream = extern struct {
    index: c_int,
    id: c_int,
    codecpar: *AVCodecParameters,
    time_base: AVRational,
};

pub const AVPacket = extern struct {
    buf: ?*anyopaque,
    pts: i64,
    dts: i64,
    data: ?[*]u8,
    size: c_int,
    stream_index: c_int,
    flags: c_int,
    side_data: ?*anyopaque,
    side_data_elems: c_int,
    duration: i64,
    pos: i64,
    @"opaque": ?*anyopaque,
    opaque_ref: ?*anyopaque,
    time_base: AVRational,
};

pub const AVIOContext = opaque {};
pub const AVDictionary = opaque {};

pub const AVFormatContext = extern struct {
    av_class: ?*const anyopaque,
    iformat: ?*const anyopaque,
    oformat: ?*const anyopaque,
    priv_data: ?*anyopaque,
    pb: ?*AVIOContext,
    ctx_flags: c_int,
    nb_streams: c_uint,
    streams: [*]?*AVStream,
};

extern fn avformat_alloc_output_context2(
    ctx: *?*AVFormatContext,
    oformat: ?*anyopaque,
    format_name: ?[*:0]const u8,
    filename: ?[*:0]const u8,
) c_int;
extern fn avformat_free_context(s: ?*AVFormatContext) void;
extern fn avformat_new_stream(s: *AVFormatContext, c: ?*anyopaque) ?*AVStream;
extern fn avformat_write_header(s: *AVFormatContext, options: *?*AVDictionary) c_int;
extern fn av_write_trailer(s: *AVFormatContext) c_int;
extern fn av_interleaved_write_frame(s: *AVFormatContext, pkt: ?*AVPacket) c_int;

extern fn avio_alloc_context(
    buffer: [*]u8,
    buffer_size: c_int,
    write_flag: c_int,
    @"opaque": ?*anyopaque,
    read_packet: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) c_int,
    write_packet: ?*const fn (?*anyopaque, [*]const u8, c_int) callconv(.c) c_int,
    seek: ?*const fn (?*anyopaque, i64, c_int) callconv(.c) i64,
) ?*AVIOContext;
extern fn avio_context_free(s: *?*AVIOContext) void;

extern fn av_packet_alloc() ?*AVPacket;
extern fn av_packet_free(pkt: *?*AVPacket) void;
extern fn av_packet_unref(pkt: *AVPacket) void;

extern fn av_dict_set(
    pm: *?*AVDictionary,
    key: [*:0]const u8,
    value: ?[*:0]const u8,
    flags: c_int,
) c_int;
extern fn av_dict_free(m: *?*AVDictionary) void;
extern fn av_malloc(size: usize) ?[*]u8;
extern fn av_free(ptr: ?*anyopaque) void;
extern fn av_rescale_q(a: i64, b: AVRational, c: AVRational) i64;

pub const OnDataFn = *const fn (ctx: ?*anyopaque, data: []const u8) void;

pub const Muxer = struct {
    format_ctx: ?*AVFormatContext = null,
    avio_ctx: ?*AVIOContext = null,
    stream: ?*AVStream = null,
    pkt: ?*AVPacket = null,
    avio_buffer: ?[*]u8 = null,
    on_data: OnDataFn,
    data_ctx: ?*anyopaque,
    header_data: std.ArrayListUnmanaged(u8) = .empty,

    header_done: bool = false,
    allocator: std.mem.Allocator,
    pts_offset: i64 = 0,
    has_pts_offset: bool = false,

    pub fn init(allocator: std.mem.Allocator, on_data: OnDataFn, data_ctx: ?*anyopaque) !*Muxer {
        const self = try allocator.create(Muxer);
        self.* = .{
            .on_data = on_data,
            .data_ctx = data_ctx,
            .allocator = allocator,
        };

        const avio_buf_size: usize = 64 * 1024;
        self.avio_buffer = av_malloc(avio_buf_size) orelse return error.OutOfMemory;

        self.avio_ctx = avio_alloc_context(
            self.avio_buffer.?,
            @intCast(avio_buf_size),
            1, // writeable
            @ptrCast(self),
            null,
            writePacketCb,
            null,
        ) orelse return error.AvioAllocFailed;

        var fmt_ctx: ?*AVFormatContext = null;
        if (avformat_alloc_output_context2(&fmt_ctx, null, "mp4", null) < 0 or fmt_ctx == null) {
            return error.AvformatAllocFailed;
        }
        self.format_ctx = fmt_ctx;
        self.format_ctx.?.pb = self.avio_ctx;

        self.stream = avformat_new_stream(self.format_ctx.?, null) orelse return error.NewStreamFailed;
        self.stream.?.codecpar.codec_type = 0; // AVMEDIA_TYPE_VIDEO
        self.stream.?.codecpar.codec_id = 27; // AV_CODEC_ID_H264
        self.stream.?.time_base = .{ .num = 1, .den = 1000 };

        var opts: ?*AVDictionary = null;
        _ = av_dict_set(&opts, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0);
        _ = av_dict_set(&opts, "brand", "iso6", 0);

        if (avformat_write_header(self.format_ctx.?, &opts) < 0) {
            av_dict_free(&opts);
            return error.WriteHeaderFailed;
        }
        av_dict_free(&opts);

        self.pkt = av_packet_alloc() orelse return error.OutOfMemory;
        self.header_done = true;
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
                self.pts_offset = pts;
                self.has_pts_offset = true;
            }

            const adj_pts = pts - self.pts_offset;
            const adj_dts = dts - self.pts_offset;

            if (timebase_den > 0 and self.stream.?.time_base.den > 0) {
                const in_tb = AVRational{ .num = timebase_num, .den = timebase_den };
                pkt.pts = av_rescale_q(adj_pts, in_tb, self.stream.?.time_base);
                pkt.dts = av_rescale_q(adj_dts, in_tb, self.stream.?.time_base);
            } else {
                pkt.pts = adj_pts;
                pkt.dts = adj_dts;
            }

            const ret = av_interleaved_write_frame(self.format_ctx.?, pkt);
            if (ret < 0) {
                return error.WriteFrameFailed;
            }
        }
    }

    pub fn getHeader(self: *Muxer) []const u8 {
        return self.header_data.items;
    }

    pub fn deinit(self: *Muxer) void {
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
