const std = @import("std");

const zignal = @import("zignal");
const cli = @import("cli");

const model = @import("model/model.zig");
const ocr = @import("ocr.zig");
const downloader = @import("downloader/mod.zig");

pub fn main(init: std.process.Init) !void {
    const result = try cli.parse(init.io, init.arena.allocator(), init.minimal.args);
    switch (result) {
        .image => |args| try runImage(init, args),
        .install => |args| try runInstall(init, args),
    }
}

fn runInstall(init: std.process.Init, args: cli.Install) !void {
    const installed = try downloader.install(init.io, init.gpa, init.environ_map, args.profile, .{ .force = args.force });
    defer init.gpa.free(installed);
    std.debug.print("installed {s}\n", .{installed});
}

fn runImage(init: std.process.Init, args: cli.Image) !void {
    const threads = if (std.mem.eql(u8, args.threads, "auto"))
        @as(i32, @intCast(@min(std.Thread.getCpuCount() catch 4, 8)))
    else
        std.fmt.parseInt(i32, args.threads, 10) catch return error.InvalidThreads;

    const model_dir = if (args.model_dir) |dir|
        try init.gpa.dupe(u8, dir)
    else
        try model.paths.profileDir(init.io, init.gpa, init.environ_map, args.profile);
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
    const rec_param = try resolve(init.gpa, args.rec_param, model_dir, rec_param_name);
    defer init.gpa.free(rec_param);
    const rec_bin = try resolve(init.gpa, args.rec_bin, model_dir, rec_bin_name);
    defer init.gpa.free(rec_bin);
    const keys = try resolve(init.gpa, args.keys, model_dir, keys_name);
    defer init.gpa.free(keys);

    if (args.detect) {
        var det = try model.det.Det.init(init.gpa, .{
            .param = det_param,
            .bin = det_bin,
            .input = det_input_name,
            .output = det_output_name,
        }, threads);
        defer det.deinit();

        const boxes = try det.detectFile(init.io, args.path);
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

    if (args.line) {
        var rec = try model.rec.Rec.init(init.gpa, init.io, .{
            .param = rec_param,
            .bin = rec_bin,
            .keys = keys,
            .input = rec_input_name,
            .output = rec_output_name,
        }, threads);
        defer rec.deinit();
        var result = try rec.recognizeFile(init.io, args.path);
        defer result.deinit(init.gpa);
        std.debug.print("{s}\n", .{result.text});
        return;
    }

    var image: zignal.Image(zignal.Rgb(u8)) = try .load(init.io, init.gpa, args.path);
    defer image.deinit(init.gpa);

    var detected = blk: {
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

        var det = try model.det.Det.init(init.gpa, .{
            .param = det_param,
            .bin = det_bin,
            .input = det_input_name,
            .output = det_output_name,
        }, threads);
        defer det.deinit();

        break :blk try ocr.detectImage(init.gpa, init.io, image, &det, if (cls) |*classifier| classifier else null);
    };
    defer detected.deinit(init.gpa);

    var rec = try model.rec.Rec.init(init.gpa, init.io, .{
        .param = rec_param,
        .bin = rec_bin,
        .keys = keys,
        .input = rec_input_name,
        .output = rec_output_name,
    }, threads);
    defer rec.deinit();

    const lines = try ocr.recognizeBoxes(init.gpa, init.io, detected.image, detected.boxes, &rec);
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
