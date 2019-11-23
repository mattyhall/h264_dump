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
    try pad(out, name, 25);
    try out.print(" ");
    try pad(out, typ, 10);
    try out.print(" {b:>8} = {}\n", raw, n);
}

const FieldType = union(enum) {
    Int: Int,
    ExpGobel: ExpGobel,
};

const Int = struct {
    bits: comptime_int,
    signed: bool = false,

    fn get_type(comptime self: *const Int) type {
        return @Type(std.builtin.TypeInfo{ .Int = std.builtin.TypeInfo.Int{ .is_signed = self.signed, .bits = self.bits } });
    }
};

const ExpGobel = struct {
    signed: bool = false,
};

const NalField = struct {
    name: []const u8,
    typ: FieldType,
};

fn parse(buf: []const u8, out: *OutStream, comptime fields: []const NalField) ![]const u8 {
    var slice_stream = io.SliceInStream.init(buf);
    var stream = io.BitInStream(std.builtin.Endian.Big, io.SliceInStream.Error).init(&slice_stream.stream);
    var bits: usize = 0;
    inline for (fields) |field| {
        switch (field.typ) {
            .Int => |int| {
                const typ = int.get_type();
                const val = stream.readBits(typ, int.bits, &bits);
                var typ_buf: [8]u8 = undefined;
                const type_s = try std.fmt.bufPrint(&typ_buf, "u({})", @intCast(u16, int.bits));
                try output(out, field.name, val, val, type_s);
            },
            .ExpGobel => |eg| {
                var num_zeros: u6 = 0;
                var read: usize = 0;
                while (true) : (num_zeros += 1) {
                    const b = try stream.readBits(u1, 1, &bits);
                    read = (read << 1) | b;
                    if (b == 1)
                        break;
                }
                const further_bits = try stream.readBits(usize, num_zeros, &bits);
                read = (read << num_zeros) | further_bits;
                const val = std.math.pow(usize, 2, num_zeros) - 1 + further_bits;
                var typ_buf: [8]u8 = undefined;
                const type_s = try std.fmt.bufPrint(&typ_buf, "ue({})", num_zeros * 2 + 1);
                try output(out, field.name, read, val, type_s);
            },
        }
    }
    return buf[slice_stream.pos..];
}

fn u(comptime bits: comptime_int) FieldType {
    return FieldType{ .Int = Int{ .bits = bits } };
}

fn ue() FieldType {
    return FieldType{ .ExpGobel = ExpGobel{} };
}

pub fn parse_nal_header(buf: []const u8, f: File) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, buf[0..3], start_code));
    const out = &f.outStream().stream;
    return parse(buf[3..], out, [_]NalField{
        NalField{ .name = "forbidden_zero_bit", .typ = u(1) },
        NalField{ .name = "nal_ref_idc", .typ = u(2) },
        NalField{ .name = "nal_unit_type", .typ = u(5) },
    });
}

pub fn parse_sps(buf: []const u8, f: File) ![]const u8 {
    const out = &f.outStream().stream;
    return parse(buf, out, [_]NalField{
        NalField{ .name = "profile_idc", .typ = u(8) },
        NalField{ .name = "constraint_set0_flag", .typ = u(1) },
        NalField{ .name = "constraint_set1_flag", .typ = u(1) },
        NalField{ .name = "constraint_set2_flag", .typ = u(1) },
        NalField{ .name = "reserved_zero_5bits", .typ = u(5) },
        NalField{ .name = "level_idc", .typ = u(8) },
        NalField{ .name = "seq_parameter_set_id", .typ = ue() },
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
