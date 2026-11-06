const std = @import("std");

const cli = @import("cli");
const config = @import("config");
const kocr = @import("kocr");

pub fn main(init: std.process.Init) !void {
    const result = try cli.parse(init.io, init.arena.allocator(), init.minimal.args);
    switch (result) {
        .image => |args| try runImage(init, args),
        .list => try runList(init),
        .use => |args| try runUse(init, args),
        .install => |args| try runInstall(init, args),
        .uninstall => |args| try runUninstall(init, args),
    }
}

fn runInstall(init: std.process.Init, args: cli.Install) !void {
    const installed = try kocr.downloader.install(init.io, init.gpa, init.environ_map, args.profile, .{ .force = args.force });
    defer init.gpa.free(installed);
    std.debug.print("installed {s}\n", .{installed});
}

fn runList(init: std.process.Init) !void {
    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();
    const selected = parsed.value.models.select;

    var found = false;
    for (kocr.downloader.catalog.profiles) |profile| {
        if (!try kocr.downloader.isInstalled(init.io, init.gpa, init.environ_map, profile)) continue;
        found = true;
        const suffix = if (selected) |name|
            if (std.mem.eql(u8, name, profile)) " (selected)" else ""
        else
            "";
        std.debug.print("{s}{s}\n", .{ profile, suffix });
    }
    if (!found) std.debug.print("no models installed\n", .{});
}

fn runUninstall(init: std.process.Init, args: cli.Uninstall) !void {
    if (!try kocr.downloader.isInstalled(init.io, init.gpa, init.environ_map, args.profile))
        return error.ModelNotInstalled;
    try kocr.downloader.remove(init.io, init.gpa, init.environ_map, args.profile);

    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();
    if (parsed.value.models.select) |selected| {
        if (std.mem.eql(u8, selected, args.profile)) {
            parsed.value.models.select = null;
            try config.save(init.gpa, init.io, init.environ_map, parsed.value);
        }
    }
    std.debug.print("uninstalled {s}\n", .{args.profile});
}

fn runUse(init: std.process.Init, args: cli.Use) !void {
    if (!try kocr.downloader.isInstalled(init.io, init.gpa, init.environ_map, args.profile))
        return error.ModelNotInstalled;
    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();
    parsed.value.models.select = args.profile;
    try config.save(init.gpa, init.io, init.environ_map, parsed.value);
    std.debug.print("using {s}\n", .{args.profile});
}

fn runImage(init: std.process.Init, args: cli.Image) !void {
    const threads: ?i32 = if (std.mem.eql(u8, args.threads, "auto"))
        null
    else
        std.fmt.parseInt(i32, args.threads, 10) catch return error.InvalidThreads;

    var parsed_config = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed_config.deinit();
    const profile = args.profile orelse parsed_config.value.models.select orelse "tiny";
    const model_dir = args.model_dir orelse
        try kocr.paths.profileDir(init.io, init.gpa, init.environ_map, profile);
    defer if (args.model_dir == null) init.gpa.free(model_dir);

    const options: kocr.Options = .{
        .model_dir = model_dir,
        .threads = threads,
        .rec_param = args.rec_param,
        .rec_bin = args.rec_bin,
        .keys = args.keys,
    };

    if (args.detect) {
        const boxes = try kocr.detectFile(init.gpa, init.io, args.path, options);
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
        var result = try kocr.recognizeLine(init.gpa, init.io, args.path, options);
        defer result.deinit(init.gpa);
        std.debug.print("{s}\n", .{result.text});
        return;
    }

    const lines = try kocr.recognizeFile(init.gpa, init.io, args.path, options);
    defer kocr.freeLines(init.gpa, lines);
    for (lines) |line| {
        std.debug.print("{s}\n", .{line.text});
    }
    try recordHistory(init, lines);
}

fn recordHistory(init: std.process.Init, lines: []const kocr.Line) !void {
    if (lines.len == 0) return;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(init.gpa);
    for (lines, 0..) |line, index| {
        if (index != 0) try text.append(init.gpa, '\n');
        try text.appendSlice(init.gpa, line.text);
    }
    kocr.history.appendText(init.io, init.gpa, init.environ_map, text.items) catch |err| {
        std.debug.print("warning: failed to save history: {s}\n", .{@errorName(err)});
    };
}
