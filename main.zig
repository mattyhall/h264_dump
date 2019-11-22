const std = @import("std");
const io = std.io;
const File = std.fs.File;

fn skip_to_start_code(buf: []const u8) []const u8 {
    const start_code = [3]u8{ 0, 0, 1 };
    var i: usize = 0;
    while (buf.len >= i + 3 and !std.mem.eql(u8, buf[i .. i + 3], start_code)) : (i += 1) {}
    return buf[i..];
}

const types: [22][]const u8 = [_][]const u8{
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var f = try File.openRead("test.264");
    defer f.close();
    var inStream = io.BufferedInStream(File.ReadError).init(&f.inStream().stream);

    var data = try inStream.stream.readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    const slice = skip_to_start_code(data[0..]);
    while (slice.len >= 3) {
        if (slice.len < 4) {
            break;
        }
        const unit_type = slice[3] & 0x1F;
        std.debug.warn("{} ({})\n", types[unit_type], unit_type);
        slice = skip_to_start_code(slice[3..]);
    }
}
