const std = @import("std");

const cli = @import("cli");
const config = @import("config");
const kocr = @import("kocr");

const profiles = kocr.downloader.catalog.profiles;

const InstallProgress = struct {
    last_percent: u8 = 101,
    printed: bool = false,

    fn report(context: *anyopaque, downloaded: u64, total: u64) void {
        const self: *InstallProgress = @ptrCast(@alignCast(context));
        if (total == 0) {
            if (!self.printed) {
                self.printed = true;
                std.debug.print("\rdownloading…", .{});
            }
            return;
        }
        const percent: u8 = @intCast(@min(100, downloaded * 100 / total));
        if (percent == self.last_percent) return;
        self.last_percent = percent;
        self.printed = true;
        std.debug.print("\rdownloading {d}%", .{percent});
    }

    fn finish(self: *InstallProgress) void {
        if (!self.printed) return;
        std.debug.print("\r                  \r", .{});
        self.printed = false;
    }
};

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

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn validateProfile(profile: []const u8) void {
    if (kocr.downloader.catalog.find(profile) == null)
        fail("unknown model profile '{s}'\nchoose tiny, small or medium\n", .{profile});
}

fn modelPath(init: std.process.Init, profile: []const u8) ![]u8 {
    return kocr.paths.profileDir(init.io, init.gpa, init.environ_map, profile);
}

fn requireInstalled(init: std.process.Init, profile: []const u8) ![]const u8 {
    validateProfile(profile);
    if (!try kocr.downloader.isInstalled(init.io, init.gpa, init.environ_map, profile))
        fail("{s} is not installed\ninstall it with: kocr install {s}\n", .{ profile, profile });
    return profile;
}

fn select(init: std.process.Init, profile: []const u8) !void {
    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();
    parsed.value.models.select = profile;
    try config.save(init.gpa, init.io, init.environ_map, parsed.value);
}

fn runInstall(init: std.process.Init, args: cli.Install) !void {
    const profile = args.profile;
    validateProfile(profile);
    var progress = InstallProgress{};
    errdefer progress.finish();
    const installed = kocr.downloader.install(init.io, init.gpa, init.environ_map, profile, .{
        .force = args.force,
        .progress = .{ .context = &progress, .report = InstallProgress.report },
    }) catch |err| switch (err) {
        error.AlreadyInstalled => {
            progress.finish();
            fail("{s} is already installed\nreinstall with: kocr install {s} --force\n", .{ profile, profile });
        },
        else => return err,
    };
    defer init.gpa.free(installed);
    progress.finish();
    std.debug.print("installed {s} at {s}\n", .{ profile, installed });
    try select(init, profile);
    std.debug.print("now using {s}\n", .{profile});
}

fn runList(init: std.process.Init) !void {
    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();
    const selected = parsed.value.models.select;

    const Row = struct {
        name: []const u8,
        status: []const u8,
        path: []u8,
    };
    var rows: [profiles.len]Row = undefined;
    for (profiles, 0..) |profile, index| {
        const installed = try kocr.downloader.isInstalled(init.io, init.gpa, init.environ_map, profile);
        const is_selected = if (selected) |name| std.mem.eql(u8, name, profile) else false;
        rows[index] = .{
            .name = profile,
            .status = if (installed) (if (is_selected) "installed, selected" else "installed") else (if (is_selected) "missing" else "not installed"),
            .path = try modelPath(init, profile),
        };
    }
    defer for (rows) |row| init.gpa.free(row.path);

    std.debug.print("{s:<6}  {s:<19}  {s}\n", .{ "NAME", "STATUS", "PATH" });
    for (rows) |row| {
        std.debug.print("{s:<6}  {s:<19}  {s}\n", .{ row.name, row.status, row.path });
    }
}

fn runUninstall(init: std.process.Init, args: cli.Uninstall) !void {
    const profile = args.profile;
    validateProfile(profile);
    if (!try kocr.downloader.isInstalled(init.io, init.gpa, init.environ_map, profile))
        fail("{s} is not installed\nrun kocr list to see installed models\n", .{profile});
    const model_dir = try modelPath(init, profile);
    defer init.gpa.free(model_dir);
    try kocr.downloader.remove(init.io, init.gpa, init.environ_map, profile);

    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();
    const was_selected = if (parsed.value.models.select) |name| std.mem.eql(u8, name, profile) else false;
    if (was_selected) {
        parsed.value.models.select = null;
        try config.save(init.gpa, init.io, init.environ_map, parsed.value);
    }
    std.debug.print("removed {s} ({s})\n", .{ profile, model_dir });
    if (was_selected) std.debug.print("no model selected\ninstall one with: kocr install <profile>\n", .{});
}

fn runUse(init: std.process.Init, args: cli.Use) !void {
    const profile = args.profile;
    _ = try requireInstalled(init, profile);
    const model_dir = try modelPath(init, profile);
    defer init.gpa.free(model_dir);

    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();
    if (parsed.value.models.select) |name| {
        if (std.mem.eql(u8, name, profile)) {
            std.debug.print("{s} is already the active model ({s})\n", .{ profile, model_dir });
            return;
        }
    }
    parsed.value.models.select = profile;
    try config.save(init.gpa, init.io, init.environ_map, parsed.value);
    std.debug.print("now using {s} ({s})\n", .{ profile, model_dir });
}

fn resolveImageProfile(init: std.process.Init, requested: ?[]const u8, selected: ?[]const u8) ![]const u8 {
    if (requested orelse selected) |profile| return requireInstalled(init, profile);
    for (profiles) |profile| {
        if (try kocr.downloader.isInstalled(init.io, init.gpa, init.environ_map, profile)) return profile;
    }
    std.debug.print("no model installed\ninstall one with:\n", .{});
    for (profiles) |profile| std.debug.print("  kocr install {s}\n", .{profile});
    std.process.exit(1);
}

fn runImage(init: std.process.Init, args: cli.Image) !void {
    const threads: ?i32 = if (std.mem.eql(u8, args.threads, "auto"))
        null
    else
        std.fmt.parseInt(i32, args.threads, 10) catch return error.InvalidThreads;

    var parsed_config = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed_config.deinit();
    const model_dir = if (args.model_dir) |dir|
        dir
    else blk: {
        const profile = try resolveImageProfile(init, args.profile, parsed_config.value.models.select);
        break :blk try modelPath(init, profile);
    };
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
