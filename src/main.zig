const std = @import("std");
const io = std.io;
const File = std.fs.File;
const clap = @import("zig-clap");

const OutStream = io.OutStream(std.os.WriteError);

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

pub fn output(out: *OutStream, name: []const u8, n: var) !void {
    try out.print("{}: {b} = {}\n", name, n, n);
}

const NalField = struct {
    name: []const u8,
    bits: comptime_int,
};

pub fn parse(buf: []const u8, out: *OutStream, comptime fields: []const NalField) ![]const u8 {
    var slice_stream = io.SliceInStream.init(buf);
    var stream = io.BitInStream(std.builtin.Endian.Big, io.SliceInStream.Error).init(&slice_stream.stream);
    var bits: usize = 0;
    inline for (fields) |field| {
        const i = @intCast(comptime_int, field.bits);
        const typ = @Type(std.builtin.TypeInfo{ .Int = std.builtin.TypeInfo.Int{ .is_signed = false, .bits = field.bits } });
        const val = stream.readBits(typ, field.bits, &bits);
        try output(out, field.name, val);
    }
    return buf[slice_stream.pos..];
}

pub fn parse_nal_header(buf: []const u8, f: File) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, buf[0..3], start_code));
    const out = &f.outStream().stream;
    return parse(buf[3..], out, [_]NalField{
        NalField{ .name = "forbidden_zero_bit", .bits = 1 },
        NalField{ .name = "nal_ref_idc", .bits = 2 },
        NalField{ .name = "nal_unit_type", .bits = 5 },
    });
}

pub fn parse_sps(buf: []const u8, f: File) ![]const u8 {
    const out = &f.outStream().stream;
    return parse(buf, out, [_]NalField{
        NalField{ .name = "profile_idc", .bits = 8 },
        NalField{ .name = "constraint_set0_flag", .bits = 1 },
        NalField{ .name = "constraint_set1_flag", .bits = 1 },
        NalField{ .name = "constraint_set2_flag", .bits = 1 },
        NalField{ .name = "reserved_zero_5bits", .bits = 5 },
        NalField{ .name = "level_idc", .bits = 8 },
    });
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
