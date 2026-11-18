const std = @import("std");

const cli = @import("cli");
const core = @import("core");
const update = @import("update.zig");

const config = core.config;

const profiles = core.downloader.catalog.profiles;

const InstallProgress = struct {
    io: std.Io,
    last_percent: u8 = 101,
    printed: bool = false,

    fn report(context: *anyopaque, downloaded: u64, total: u64) void {
        const self: *InstallProgress = @ptrCast(@alignCast(context));
        if (total == 0) {
            if (!self.printed) {
                self.printed = true;
                stderrPrint(self.io, "\rdownloading…", .{});
            }
            return;
        }
        const percent: u8 = @intCast(@min(100, downloaded * 100 / total));
        if (percent == self.last_percent) return;
        self.last_percent = percent;
        self.printed = true;
        stderrPrint(self.io, "\rdownloading {d}%", .{percent});
    }

    fn finish(self: *InstallProgress) void {
        if (!self.printed) return;
        stderrPrint(self.io, "\r                  \r", .{});
        self.printed = false;
    }
};

/// Progress ticks have no trailing newline, so they bypass `std.log`.
fn stderrPrint(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

const App = struct {
    out: *std.Io.Writer,

    pub fn handleImage(self: *const App, init: std.process.Init, args: cli.Image) !void {
        const out = self.out;
        const threads = try parseThreads(args.threads);

        var parsed_config = try config.load(init.gpa, init.io, init.environ_map);
        defer parsed_config.deinit();

        const model_dir = if (args.model_dir) |dir| dir else blk: {
            const profile = try resolveImageProfile(
                init,
                args.profile,
                parsed_config.value.models.select,
            );
            break :blk try modelPath(init, profile);
        };
        defer {
            if (args.model_dir == null) init.gpa.free(model_dir);
        }

        const options: core.Options = .{
            .model_dir = model_dir,
            .threads = threads,
            .rec_param = args.rec_param,
            .rec_bin = args.rec_bin,
            .keys = args.keys,
        };

        if (args.detect) {
            const boxes = try core.detectFile(init.gpa, init.io, args.path, options);
            defer init.gpa.free(boxes);

            for (boxes, 0..) |box, index| {
                try out.print("{d}: [{d},{d},{d},{d}]\n", .{
                    index,
                    box.bounds.left,
                    box.bounds.top,
                    box.bounds.right,
                    box.bounds.bottom,
                });
            }
            try out.print("{d} boxes\n", .{boxes.len});
            return;
        }

        if (args.line) {
            var result = try core.recognizeLine(init.gpa, init.io, args.path, options);
            defer result.deinit(init.gpa);
            try out.print("{s}\n", .{result.text});
            return;
        }

        const lines = try core.recognizeFile(init.gpa, init.io, args.path, options);
        defer core.freeLines(init.gpa, lines);

        for (lines) |line| {
            try out.print("{s}\n", .{line.text});
        }
        try recordHistory(init, lines);
    }

    pub fn handleList(self: *const App, init: std.process.Init) !void {
        const out = self.out;
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
            const installed = try core.downloader.isInstalled(
                init.io,
                init.gpa,
                init.environ_map,
                profile,
            );
            rows[index] = .{
                .name = profile,
                .status = statusText(installed, isSelected(selected, profile)),
                .path = try modelPath(init, profile),
            };
        }
        defer {
            for (rows) |row| init.gpa.free(row.path);
        }

        try out.print("{s:<6}  {s:<19}  {s}\n", .{ "NAME", "STATUS", "PATH" });
        for (rows) |row| {
            try out.print("{s:<6}  {s:<19}  {s}\n", .{ row.name, row.status, row.path });
        }
    }

    pub fn handleUse(self: *const App, init: std.process.Init, args: cli.Use) !void {
        const out = self.out;
        const profile = args.profile;
        _ = try requireInstalled(init, profile);

        const model_dir = try modelPath(init, profile);
        defer init.gpa.free(model_dir);

        var parsed = try config.load(init.gpa, init.io, init.environ_map);
        defer parsed.deinit();

        if (isSelected(parsed.value.models.select, profile)) {
            try out.print("{s} is already the active model ({s})\n", .{ profile, model_dir });
            return;
        }

        parsed.value.models.select = profile;
        try config.save(init.gpa, init.io, init.environ_map, parsed.value);
        try out.print("now using {s} ({s})\n", .{ profile, model_dir });
    }

    pub fn handleInstall(self: *const App, init: std.process.Init, args: cli.Install) !void {
        const out = self.out;
        const profile = args.profile;
        validateProfile(profile);

        var progress = InstallProgress{ .io = init.io };
        errdefer progress.finish();

        const installed = core.downloader.install(
            init,
            profile,
            .{
                .force = args.force,
                .progress = .{
                    .context = &progress,
                    .report = InstallProgress.report,
                },
            },
        ) catch |err| switch (err) {
            error.AlreadyInstalled => {
                progress.finish();
                fail(
                    "{s} is already installed\n" ++
                        "reinstall with: kocr install {s} --force\n",
                    .{ profile, profile },
                );
            },
            else => return err,
        };
        defer init.gpa.free(installed);

        progress.finish();
        try out.print("installed {s} at {s}\n", .{ profile, installed });
        try select(init, profile);
        try out.print("now using {s}\n", .{profile});
    }

    pub fn handleUpdate(self: *const App, init: std.process.Init) !void {
        var progress = InstallProgress{ .io = init.io };
        defer progress.finish();
        const version = update.run(init, .{
            .context = &progress,
            .report = InstallProgress.report,
        }) catch |err| {
            progress.finish();
            fail("Update failed: {s}", .{@errorName(err)});
        };
        progress.finish();
        if (version) |new_version| {
            try self.out.print("Updated kocr to {s}.\n", .{new_version});
        } else {
            try self.out.print("kocr {s} is up to date.\n", .{update.current_version});
        }
    }

    pub fn handleUninstall(self: *const App, init: std.process.Init, args: cli.Uninstall) !void {
        const out = self.out;
        const profile = args.profile;
        validateProfile(profile);

        if (!try core.downloader.isInstalled(init.io, init.gpa, init.environ_map, profile)) {
            fail(
                "{s} is not installed\n" ++
                    "run kocr list to see installed models\n",
                .{profile},
            );
        }

        const model_dir = try modelPath(init, profile);
        defer init.gpa.free(model_dir);

        try core.downloader.remove(init.io, init.gpa, init.environ_map, profile);

        var parsed = try config.load(init.gpa, init.io, init.environ_map);
        defer parsed.deinit();

        const was_selected = isSelected(parsed.value.models.select, profile);
        if (was_selected) {
            parsed.value.models.select = null;
            try config.save(init.gpa, init.io, init.environ_map, parsed.value);
        }

        try out.print("removed {s} ({s})\n", .{ profile, model_dir });
        if (was_selected) {
            try out.print(
                "no model selected\n" ++
                    "install one with: kocr install <profile>\n",
                .{},
            );
        }
    }

    fn resolveImageProfile(
        init: std.process.Init,
        requested: ?[]const u8,
        selected: ?[]const u8,
    ) ![]const u8 {
        if (requested orelse selected) |profile| {
            return requireInstalled(init, profile);
        }

        for (profiles) |profile| {
            const installed = try core.downloader.isInstalled(
                init.io,
                init.gpa,
                init.environ_map,
                profile,
            );
            if (installed) return profile;
        }

        var buffer: [128]u8 = undefined;
        var message = std.Io.Writer.fixed(&buffer);
        message.print("no model installed\ninstall one with:", .{}) catch {};
        for (profiles) |profile| {
            message.print("\n  kocr install {s}", .{profile}) catch {};
        }

        std.log.err("{s}", .{message.buffered()});
        std.process.exit(1);
    }
};

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(20_000);
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);

    const out = &file_writer.interface;
    defer out.flush() catch {};

    var app = App{ .out = out };
    try cli.run(init, &app);
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

fn isSelected(selected: ?[]const u8, profile: []const u8) bool {
    const name = selected orelse return false;
    return std.mem.eql(u8, name, profile);
}

fn statusText(installed: bool, selected: bool) []const u8 {
    if (installed) {
        return if (selected) "installed, selected" else "installed";
    }
    return if (selected) "missing" else "not installed";
}

fn parseThreads(value: []const u8) !?i32 {
    if (std.mem.eql(u8, value, "auto")) return null;
    return std.fmt.parseInt(i32, value, 10) catch error.InvalidThreads;
}

fn validateProfile(profile: []const u8) void {
    if (core.downloader.catalog.find(profile) == null) {
        fail("unknown model profile '{s}'\nchoose tiny, small or medium", .{profile});
    }
}

fn modelPath(init: std.process.Init, profile: []const u8) ![]u8 {
    return core.paths.profileDir(init.gpa, init.environ_map, profile);
}

fn requireInstalled(init: std.process.Init, profile: []const u8) ![]const u8 {
    validateProfile(profile);

    if (!try core.downloader.isInstalled(init.io, init.gpa, init.environ_map, profile)) {
        fail("{s} is not installed\ninstall it with: kocr install {s}", .{ profile, profile });
    }

    return profile;
}

fn select(init: std.process.Init, profile: []const u8) !void {
    var parsed = try config.load(init.gpa, init.io, init.environ_map);
    defer parsed.deinit();

    parsed.value.models.select = profile;
    try config.save(init.gpa, init.io, init.environ_map, parsed.value);
}

fn recordHistory(init: std.process.Init, lines: []const core.Line) !void {
    if (lines.len == 0) return;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(init.gpa);
    for (lines, 0..) |line, index| {
        if (index != 0) try text.append(init.gpa, '\n');
        try text.appendSlice(init.gpa, line.text);
    }

    core.history.appendText(init.io, init.gpa, init.environ_map, text.items) catch |err| {
        std.log.warn("failed to save history: {s}", .{@errorName(err)});
    };
}
