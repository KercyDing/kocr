const std = @import("std");

const model = @import("model/model.zig");

const usage =
    \\usage: kocr <image> [options]
    \\
    \\  --profile <name>    tiny, small or medium (default: tiny)
    \\  --model-dir <path>  model directory
    \\  --rec-param <path>  recognition .param
    \\  --rec-bin <path>    recognition .bin
    \\  --keys <path>       dictionary
    \\  --threads <n>       inference threads (default: 1)
    \\
;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var image_path: ?[]const u8 = null;
    var profile: []const u8 = "tiny";
    var model_dir_arg: ?[]const u8 = null;
    var rec_param_arg: ?[]const u8 = null;
    var rec_bin_arg: ?[]const u8 = null;
    var keys_arg: ?[]const u8 = null;
    var threads: i32 = 1;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            profile = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--model-dir")) {
            model_dir_arg = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--rec-param")) {
            rec_param_arg = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--rec-bin")) {
            rec_bin_arg = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--keys")) {
            keys_arg = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const value = args.next() orelse return usageError();
            threads = std.fmt.parseInt(i32, value, 10) catch return usageError();
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageError();
        } else if (image_path == null) {
            image_path = arg;
        } else {
            return usageError();
        }
    }

    const path = image_path orelse return usageError();

    const model_dir = if (model_dir_arg) |dir|
        try init.gpa.dupe(u8, dir)
    else
        try model.paths.profileDir(init.io, init.gpa, init.environ_map, profile);
    defer init.gpa.free(model_dir);

    var manifest = try model.loadManifest(init.gpa, init.io, model_dir);
    defer if (manifest) |*parsed| parsed.deinit();

    const rec_param_name = if (manifest) |parsed| parsed.value.rec.param else "rec.param";
    const rec_bin_name = if (manifest) |parsed| parsed.value.rec.bin else "rec.bin";
    const keys_name = if (manifest) |parsed| parsed.value.keys else "keys.txt";

    const rec_param = try resolve(init.gpa, rec_param_arg, model_dir, rec_param_name);
    defer init.gpa.free(rec_param);
    const rec_bin = try resolve(init.gpa, rec_bin_arg, model_dir, rec_bin_name);
    defer init.gpa.free(rec_bin);
    const keys = try resolve(init.gpa, keys_arg, model_dir, keys_name);
    defer init.gpa.free(keys);

    var rec = try model.rec.Rec.init(init.gpa, init.io, .{
        .param = rec_param,
        .bin = rec_bin,
        .keys = keys,
    }, threads);
    defer rec.deinit();

    var result = try rec.recognizeFile(init.io, path);
    defer result.deinit(init.gpa);
    std.debug.print("{s}\n", .{result.text});
}

fn resolve(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    dir: []const u8,
    name: []const u8,
) ![]u8 {
    if (override) |path| return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ dir, name });
}

fn usageError() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
