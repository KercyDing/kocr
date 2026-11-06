const std = @import("std");
const zignal = @import("zignal");

const model = @import("model/model.zig");
const ocr = @import("ocr.zig");

const usage =
    \\usage: kocr <image> [options]
    \\
    \\  --profile <name>    tiny, small or medium (default: tiny)
    \\  --model-dir <path>  model directory
    \\  --rec-param <path>  recognition .param
    \\  --rec-bin <path>    recognition .bin
    \\  --keys <path>       dictionary
    \\  --threads <n>       inference threads (default: auto)
    \\  --detect            print detected text boxes
    \\  --line              recognize a single text line (skip detection)
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
    var threads_arg: ?i32 = null;
    var detect_only = false;
    var line_only = false;

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
        } else if (std.mem.eql(u8, arg, "--detect")) {
            detect_only = true;
        } else if (std.mem.eql(u8, arg, "--line")) {
            line_only = true;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const value = args.next() orelse return usageError();
            threads_arg = std.fmt.parseInt(i32, value, 10) catch return usageError();
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageError();
        } else if (image_path == null) {
            image_path = arg;
        } else {
            return usageError();
        }
    }

    const path = image_path orelse return usageError();
    const threads = threads_arg orelse @as(i32, @intCast(@min(std.Thread.getCpuCount() catch 4, 8)));

    const model_dir = if (model_dir_arg) |dir|
        try init.gpa.dupe(u8, dir)
    else
        try model.paths.profileDir(init.io, init.gpa, init.environ_map, profile);
    defer init.gpa.free(model_dir);

    var manifest = try model.loadManifest(init.gpa, init.io, model_dir);
    defer if (manifest) |*parsed| parsed.deinit();

    const det_param_name = if (manifest) |parsed| parsed.value.det.param else "det.param";
    const det_bin_name = if (manifest) |parsed| parsed.value.det.bin else "det.bin";
    const det_input_name = if (manifest) |parsed| parsed.value.det.input else "input";
    const det_output_name = if (manifest) |parsed| parsed.value.det.output else "output";
    const rec_input_name = if (manifest) |parsed| parsed.value.rec.input else "input";
    const rec_output_name = if (manifest) |parsed| parsed.value.rec.output else "output";
    const cls_names = if (manifest) |parsed| parsed.value.cls else null;
    const rec_param_name = if (manifest) |parsed| parsed.value.rec.param else "rec.param";
    const rec_bin_name = if (manifest) |parsed| parsed.value.rec.bin else "rec.bin";
    const keys_name = if (manifest) |parsed| parsed.value.keys else "keys.txt";

    const det_param = try resolve(init.gpa, null, model_dir, det_param_name);
    defer init.gpa.free(det_param);
    const det_bin = try resolve(init.gpa, null, model_dir, det_bin_name);
    defer init.gpa.free(det_bin);
    const rec_param = try resolve(init.gpa, rec_param_arg, model_dir, rec_param_name);
    defer init.gpa.free(rec_param);
    const rec_bin = try resolve(init.gpa, rec_bin_arg, model_dir, rec_bin_name);
    defer init.gpa.free(rec_bin);
    const keys = try resolve(init.gpa, keys_arg, model_dir, keys_name);
    defer init.gpa.free(keys);

    if (detect_only) {
        var det = try model.det.Det.init(init.gpa, .{
            .param = det_param,
            .bin = det_bin,
            .input = det_input_name,
            .output = det_output_name,
        }, threads);
        defer det.deinit();

        const boxes = try det.detectFile(init.io, path);
        defer init.gpa.free(boxes);
        for (boxes, 0..) |box, index| {
            std.debug.print("{d}: [{d},{d},{d},{d}]\n", .{
                index,
                box.bounds.left,
                box.bounds.top,
                box.bounds.right,
                box.bounds.bottom,
            });
        }
        std.debug.print("{d} boxes\n", .{boxes.len});
        return;
    }

    var cls: ?model.cls.Cls = null;
    if (cls_names) |names| {
        const cls_param = try resolve(init.gpa, null, model_dir, names.param);
        defer init.gpa.free(cls_param);
        const cls_bin = try resolve(init.gpa, null, model_dir, names.bin);
        defer init.gpa.free(cls_bin);
        cls = try model.cls.Cls.init(init.gpa, .{
            .param = cls_param,
            .bin = cls_bin,
            .input = names.input,
            .output = names.output,
        }, 1);
    }
    defer if (cls) |*classifier| classifier.deinit();

    var rec = try model.rec.Rec.init(init.gpa, init.io, .{
        .param = rec_param,
        .bin = rec_bin,
        .keys = keys,
        .input = rec_input_name,
        .output = rec_output_name,
    }, threads);
    defer rec.deinit();

    if (line_only) {
        var result = try rec.recognizeFile(init.io, path);
        defer result.deinit(init.gpa);
        std.debug.print("{s}\n", .{result.text});
        return;
    }

    var image: zignal.Image(zignal.Rgb(u8)) = try .load(init.io, init.gpa, path);
    defer image.deinit(init.gpa);

    var det = try model.det.Det.init(init.gpa, .{
        .param = det_param,
        .bin = det_bin,
        .input = det_input_name,
        .output = det_output_name,
    }, threads);
    defer det.deinit();

    const lines = try ocr.recognizeImage(init.gpa, init.io, image, &det, &rec, if (cls) |*classifier| classifier else null);
    defer ocr.freeLines(init.gpa, lines);
    for (lines) |line| {
        std.debug.print("{s}\n", .{line.text});
    }
}

fn resolve(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    dir: []const u8,
    name: []const u8,
) ![]u8 {
    if (override) |path| return allocator.dupe(u8, path);
    return std.Io.Dir.path.join(allocator, &.{ dir, name });
}

fn usageError() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
