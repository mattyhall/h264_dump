const std = @import("std");
const io = std.io;
const File = std.fs.File;
const clap = @import("zig-clap");

const OutStream = io.OutStream(std.os.WriteError);
const BitInStream = io.BitInStream(std.builtin.Endian.Big, io.SliceInStream.Error);

const start_code = [3]u8{ 0, 0, 1 };

fn skip_to_start_code(buf: []const u8) []const u8 {
    var i: usize = 0;
    while (buf.len >= i + 3 and !std.mem.eql(u8, buf[i .. i + 3], start_code)) : (i += 1) {}
    return buf[i..];
}

const UnitType = enum {
    Unspecified,
    NonIDR,
    PartitionA,
    PartitionB,
    PartitionC,
    IDR,
    SEI,
    SPS,
    PPS,
    UnitDelimiter,
    EOSeq,
    EOStream,
    Filler,
    SPSExtension,
    Prefix,
    SPSSubset,
    CodedSlice = 19,
    CodedSliceExtension,
    CodedSliceExtensionDepth,
};

const types = [_][]const u8{
    "Unspecified",
    "Non-IDR",
    "Partition A",
    "Partition B",
    "Partition C",
    "IDR",
    "SEI",
    "SPS",
    "PPS",
    "Access unit delimiter",
    "End of sequence",
    "End of stream",
    "Filler data",
    "SPS extension",
    "Prefix NAL unit",
    "Subset SPS",
    "",
    "",
    "",
    "Coded slice of an auxilary coded picture without partitioning",
    "Coded slice extension",
    "Coded slice extension for depth view components",
};

fn pad(out: *OutStream, s: []const u8, n: usize) !void {
    std.debug.assert(n >= s.len);
    var i = n - s.len;
    try out.print("{}", s);
    while (i > 0) : (i -= 1) {
        try out.print(" ");
    }
}

// FIXME: Workaround for padding strings
fn output(out: *OutStream, name: []const u8, raw: var, n: var, typ: []const u8) !void {
    try pad(out, name, 50);
    try out.print(" ");
    try pad(out, typ, 10);
    try out.print(" {b:>8} = {}\n", raw, n);
}

fn int_type(comptime bits: comptime_int) type {
    return @Type(std.builtin.TypeInfo{ .Int = std.builtin.TypeInfo.Int{ .is_signed = false, .bits = bits } });
}

fn u(stream: *BitInStream, out: *OutStream, name: []const u8, comptime bits: comptime_int) !int_type(bits) {
    const typ = int_type(bits);
    var bit_target: usize = undefined;
    const val = stream.readBits(typ, bits, &bit_target);
    var typ_buf: [8]u8 = undefined;
    const type_s = try std.fmt.bufPrint(&typ_buf, "u({})", @intCast(u16, bits));
    try output(out, name, val, val, type_s);
    return val;
}

const ExpGolomb = struct {
    zeros: u6,
    val: usize,
    read: usize,
};

fn eg(stream: *BitInStream) io.SliceInStream.Error!ExpGolomb {
    var num_zeros: u6 = 0;
    var read: usize = 0;
    var bits: usize = undefined;
    while (true) : (num_zeros += 1) {
        const b = try stream.readBits(u1, 1, &bits);
        read = (read << 1) | b;
        if (b == 1)
            break;
    }
    const further_bits = try stream.readBits(usize, num_zeros, &bits);
    read = (read << num_zeros) | further_bits;
    const val = std.math.pow(usize, 2, num_zeros) - 1 + further_bits;
    return ExpGolomb{
        .zeros = num_zeros,
        .val = val,
        .read = read,
    };
}

fn ue(stream: *BitInStream, out: *OutStream, name: []const u8) !usize {
    const res = try eg(stream);
    var typ_buf: [8]u8 = undefined;
    const type_s = try std.fmt.bufPrint(&typ_buf, "ue({})", res.zeros * 2 + 1);
    try output(out, name, res.read, res.val, type_s);
    return res.val;
}

fn se(stream: *BitInStream, out: *OutStream, name: []const u8) !isize {
    const res = try eg(stream);
    var typ_buf: [8]u8 = undefined;
    const type_s = try std.fmt.bufPrint(&typ_buf, "se({})", res.zeros * 2 + 1);
    const k = @intCast(isize, res.val);
    const val = std.math.pow(isize, -1, k + 1) * @floatToInt(isize, std.math.ceil(@intToFloat(f32, k) / 2.0));
    try output(out, name, res.read, val, type_s);
    return val;
}

pub fn parse_nal_header(buf: []const u8, f: File) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, buf[0..3], start_code));
    const out = &f.outStream().stream;
    var slice_stream = io.SliceInStream.init(buf[3..]);
    var stream = BitInStream.init(&slice_stream.stream);

    _ = try u(&stream, out, "forbidden_zero_bit", 1);
    _ = try u(&stream, out, "nal_ref_idc", 2);
    _ = try u(&stream, out, "nal_unit_type", 5);

    return buf[3 + slice_stream.pos ..];
}

pub fn parse_sps(buf: []const u8, f: File) ![]const u8 {
    const out = &f.outStream().stream;
    var slice_stream = io.SliceInStream.init(buf);
    var stream = BitInStream.init(&slice_stream.stream);

    const profile_idc = try u(&stream, out, "profile_idc", 8);
    _ = try u(&stream, out, "constraint_set0_flag", 1);
    _ = try u(&stream, out, "constraint_set1_flag", 1);
    _ = try u(&stream, out, "constraint_set2_flag", 1);
    _ = try u(&stream, out, "constraint_set3_flag", 1);
    _ = try u(&stream, out, "constraint_set4_flag", 1);
    _ = try u(&stream, out, "constraint_set5_flag", 1);
    _ = try u(&stream, out, "reserved_zero_2bits", 2);
    _ = try u(&stream, out, "level_idc", 8);
    _ = try ue(&stream, out, "seq_parameter_set_id");

    if (profile_idc == 100 or profile_idc == 110 or
        profile_idc == 122 or profile_idc == 244 or profile_idc == 44 or
        profile_idc == 83 or profile_idc == 86 or profile_idc == 118 or
        profile_idc == 128 or profile_idc == 138 or profile_idc == 139 or
        profile_idc == 134)
    {
        const chroma_format_ide = try ue(&stream, out, "chroma_format_ide");
        if (chroma_format_ide == 3)
            _ = try u(&stream, out, "separate_colour_plane_flag", 1);

        _ = try ue(&stream, out, "bit_depth_luma_minus8");
        _ = try ue(&stream, out, "bit_depth_chroma_minus8");
        _ = try u(&stream, out, "qpprime_y_zero_transform_bypass_flag", 1);

        const seq_scaling_matrix_present_flag = try u(&stream, out, "seq_scaling_matrix_present_flag", 1);
        if (seq_scaling_matrix_present_flag == 1) {
            var i: usize = 0;
            const max: usize = if (chroma_format_ide != 3) 8 else 12;
            while (i < max) : (i += 1) {}
            unreachable; // TODO
        }

        _ = try ue(&stream, out, "log2_max_frame_num_minus4");

        const pic_order_cnt_type = try ue(&stream, out, "pic_order_cnt_type");
        if (pic_order_cnt_type == 0) {
            _ = try ue(&stream, out, "log2_max_pic_order_cnt_lsb_minus4");
        } else if (pic_order_cnt_type == 1) {
            _ = try u(&stream, out, "delta_pic_order_always_zero_flag", 1);
            _ = try se(&stream, out, "offset_for_non_ref_pic");
            _ = try se(&stream, out, "offset_for_top_to_bottom_field");
            const num_ref_frames_in_pic_order_cnt_cycle = try ue(&stream, out, "num_ref_frames_in_pic_order_cnt_cycle");
            var i: usize = 0;
            while (i < num_ref_frames_in_pic_order_cnt_cycle) : (i += 1) {
                const name_prefix = "offset_for_ref_frame";
                var name_buf: [name_prefix.len + 8]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "{}[{}]", name_prefix, i);
                _ = try se(&stream, out, name);
            }
        }

        _ = try ue(&stream, out, "max_num_ref_frames");
        _ = try u(&stream, out, "gaps_in_frame_num_value_allowed_flag", 1);
        _ = try ue(&stream, out, "pic_width_in_mbs_minus1");
        _ = try ue(&stream, out, "pic_height_in_map_units_minus1");

        const frame_mbs_only_flag = try u(&stream, out, "frame_mbs_only_flag", 1);
        if (frame_mbs_only_flag != 1)
            _ = try u(&stream, out, "mb_adaptive_frame_field_flag", 1);

        _ = try u(&stream, out, "direct_8x8_inference_flag", 1);

        const frame_cropping_flag = try u(&stream, out, "frame_cropping_flag", 1);
        if (frame_cropping_flag == 1) {
            _ = try ue(&stream, out, "frame_crop_left_offset");
            _ = try ue(&stream, out, "frame_crop_right_offset");
            _ = try ue(&stream, out, "frame_crop_top_offset");
            _ = try ue(&stream, out, "frame_crop_bottom_offset");
        }

        const vui_parameters_present_flag = try u(&stream, out, "vui_parameters_present_flag", 1);
        if (vui_parameters_present_flag == 1) {
            // TODO
        }
    }

    return buf[slice_stream.pos..];
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help          Display this help and exit") catch unreachable,
        clap.parseParam("-i, --input <FILE>  Read in FILE              ") catch unreachable,
        clap.parseParam("-s, --short         Only output NAL unit types") catch unreachable,
    };
    var iter = try clap.args.OsIterator.init(allocator);
    defer iter.deinit();
    var args = try clap.ComptimeClap(clap.Help, params).parse(allocator, clap.args.OsIterator, &iter);
    defer args.deinit();

    var f = if (args.option("--input")) |path| b: {
        var f = File.openRead(path) catch |e| {
            std.debug.warn("Could not open file {}\n", path);
            return 1;
        };
        break :b f;
    } else {
        std.debug.warn("Please pass a .264 file using -i\n");
        return 1;
    };
    defer f.close();
    var short = args.flag("--short");

    var stdout = &std.io.getStdOut().outStream().stream;
    var inStream = io.BufferedInStream(File.ReadError).init(&f.inStream().stream);

    var data = try inStream.stream.readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var slice = skip_to_start_code(data[0..]);
    while (slice.len >= 3) {
        const unit_type = slice[3] & 0x1F;
        if (short) {
            try stdout.print("{}\n", types[unit_type]);
        } else {
            try stdout.print("===== {} =====\n", types[unit_type]);
            slice = try parse_nal_header(slice, io.getStdOut());
            if (unit_type == @enumToInt(UnitType.SPS))
                slice = try parse_sps(slice, io.getStdOut());
        }
        slice = skip_to_start_code(slice[3..]);
    }
    return 0;
}
