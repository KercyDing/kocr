//! Minimal native Qt6 settings window: model management and OCR history.
//! Capture shortcuts and the daemon are not implemented yet.

const std = @import("std");

const kocr = @import("kocr");
const qt6 = @import("libqt6zig");

const QApplication = qt6.QApplication;
const QComboBox = qt6.QComboBox;
const QHBoxLayout = qt6.QHBoxLayout;
const QLabel = qt6.QLabel;
const QListWidget = qt6.QListWidget;
const QPushButton = qt6.QPushButton;
const QTimer = qt6.QTimer;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const JobKind = enum { install, remove };

const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    kind: JobKind,
    profile: []u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    error_text: ?[]u8 = null,
    thread: ?std.Thread = null,

    fn deinit(self: *Job) void {
        if (self.error_text) |text| self.allocator.free(text);
        self.allocator.free(self.profile);
        self.allocator.destroy(self);
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    root: QWidget,
    profile: QComboBox,
    model_status: QLabel,
    install: QPushButton,
    remove: QPushButton,
    history: QListWidget,
    copy: QPushButton,
    clear: QPushButton,
    status: QLabel,
    timer: QTimer,
    records: []kocr.history.Record = &.{},
    job: ?*Job = null,

    fn setBusy(self: *App, busy: bool) void {
        self.profile.setEnabled(!busy);
        self.install.setEnabled(!busy);
        self.remove.setEnabled(!busy);
        self.copy.setEnabled(!busy);
        self.clear.setEnabled(!busy);
    }

    fn selectedProfile(self: *App) ?[]u8 {
        const text = self.profile.currentText(self.allocator);
        defer self.allocator.free(text);
        return self.allocator.dupe(u8, text) catch {
            self.status.setText("Error: unable to allocate profile name");
            return null;
        };
    }

    fn updateModelStatus(self: *App) void {
        const profile = self.profile.currentText(self.allocator);
        defer self.allocator.free(profile);
        var message: [512]u8 = undefined;
        const installed = kocr.downloader.isInstalled(self.io, self.allocator, self.environ, profile) catch |err| {
            self.model_status.setText(std.fmt.bufPrint(&message, "Model status error: {s}", .{@errorName(err)}) catch "Model status error");
            return;
        };
        if (installed) {
            const path = kocr.paths.profileDir(self.io, self.allocator, self.environ, profile) catch |err| {
                self.model_status.setText(std.fmt.bufPrint(&message, "Model path error: {s}", .{@errorName(err)}) catch "Model path error");
                return;
            };
            defer self.allocator.free(path);
            self.model_status.setText(std.fmt.bufPrint(&message, "Installed: {s}", .{path}) catch "Installed");
            self.install.setEnabled(false);
            self.remove.setEnabled(self.job == null);
        } else {
            self.model_status.setText("Not installed");
            self.install.setEnabled(self.job == null);
            self.remove.setEnabled(false);
        }
    }

    fn loadHistory(self: *App) void {
        kocr.history.freeRecords(self.allocator, self.records);
        self.records = &.{};
        self.history.clear();

        self.records = kocr.history.recent(self.io, self.allocator, self.environ, 200) catch |err| {
            var message: [256]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&message, "History error: {s}", .{@errorName(err)}) catch "History error");
            return;
        };
        for (self.records) |record| {
            const line = historyLabel(self.allocator, record) catch continue;
            defer self.allocator.free(line);
            self.history.addItem(line);
        }
        if (self.records.len == 0) {
            self.status.setText("No history yet");
        } else if (self.history.currentRow() < 0) {
            self.history.setCurrentRow(0);
        }
    }

    fn start(self: *App, kind: JobKind) void {
        if (self.job != null) return;
        const profile = self.selectedProfile() orelse return;

        const job = self.allocator.create(Job) catch {
            self.allocator.free(profile);
            self.status.setText("Error: unable to allocate job");
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .kind = kind,
            .profile = profile,
        };
        self.job = job;
        self.setBusy(true);
        self.status.setText(if (kind == .install) "Installing model…" else "Removing model…");
        job.thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            self.job = null;
            self.setBusy(false);
            self.status.setText("Error: unable to start worker thread");
            job.deinit();
            return;
        };
        self.timer.start(50);
    }

    fn poll(self: *App) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        self.timer.stop();
        if (job.thread) |thread| thread.join();
        const error_text = job.error_text;
        job.error_text = null;
        const kind = job.kind;
        self.job = null;
        self.setBusy(false);
        self.updateModelStatus();
        if (error_text) |text| {
            self.status.setText(text);
            self.allocator.free(text);
        } else {
            self.status.setText(if (kind == .install) "Model installed" else "Model removed");
        }
        job.deinit();
    }

    fn copySelected(self: *App) void {
        const row = self.history.currentRow();
        if (row < 0 or row >= self.records.len) {
            self.status.setText("Select a history entry first");
            return;
        }
        QApplication.clipboard().setText(self.records[@intCast(row)].text);
        self.status.setText("Copied to clipboard");
    }

    fn clearHistory(self: *App) void {
        kocr.history.clear(self.io, self.allocator, self.environ) catch |err| {
            var message: [256]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&message, "Clear failed: {s}", .{@errorName(err)}) catch "Clear failed");
            return;
        };
        self.loadHistory();
        self.status.setText("History cleared");
    }
};

fn worker(job: *Job) void {
    switch (job.kind) {
        .install => {
            _ = kocr.downloader.install(job.io, job.allocator, job.environ, job.profile, .{ .force = false }) catch |err| {
                setError(job, err);
                job.done.store(true, .release);
                return;
            };
        },
        .remove => {
            kocr.downloader.remove(job.io, job.allocator, job.environ, job.profile) catch |err| {
                setError(job, err);
                job.done.store(true, .release);
                return;
            };
        },
    }
    job.done.store(true, .release);
}

fn setError(job: *Job, err: anyerror) void {
    job.error_text = std.fmt.allocPrint(job.allocator, "Error: {s}", .{@errorName(err)}) catch null;
}

fn historyLabel(allocator: std.mem.Allocator, record: kocr.history.Record) ![]u8 {
    const end = std.mem.indexOfScalar(u8, record.text, '\n') orelse record.text.len;
    const preview = record.text[0..@min(end, 96)];
    return std.fmt.allocPrint(allocator, "{s}  {s}", .{ formatTime(record.created_at), preview });
}

fn formatTime(timestamp: i64) []const u8 {
    const secs: u64 = if (timestamp > 0) @intCast(timestamp) else 0;
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const date = day.calculateMonthDay();
    const parts = epoch.getDaySeconds();
    return std.fmt.bufPrint(&time_buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        day.year,
        date.month.numeric(),
        date.day_index + 1,
        parts.getHoursIntoDay(),
        parts.getMinutesIntoHour(),
    }) catch "---- -- --:--";
}

var time_buffer: [32]u8 = undefined;
var active_app: ?*App = null;

fn pollCallback(_: QTimer) callconv(.c) void {
    if (active_app) |app| app.poll();
}

fn installCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.start(.install);
}

fn removeCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.start(.remove);
}

fn refreshModelCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.updateModelStatus();
}

fn profileChanged(_: QComboBox, _: i32) callconv(.c) void {
    if (active_app) |app| app.updateModelStatus();
}

fn copyCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.copySelected();
}

fn clearCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.clearHistory();
}

fn refreshHistoryCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.loadHistory();
}

fn closeCallback(_: QWidget, _: qt6.QCloseEvent) callconv(.c) void {
    if (active_app) |app| {
        app.timer.stop();
        if (app.job) |job| {
            if (job.thread) |thread| thread.join();
            app.job = null;
            job.deinit();
        }
    }
}

pub fn run(init: std.process.Init) !void {
    const argv = try qt6.init(init.gpa, init.minimal.args);
    defer qt6.deinit(init.gpa, argv);
    var argc: i32 = @intCast(argv.len);
    const qapp = QApplication.new(init.arena.allocator(), &argc, argv);
    defer qapp.delete();

    const root = QWidget.new2();
    defer root.delete();
    root.setObjectName("kocrWindow");
    root.setWindowTitle("kocr");
    root.resize(760, 560);
    root.onCloseEvent(closeCallback);

    const title = QLabel.new3("kocr settings");
    title.setObjectName("titleLabel");

    const profile = QComboBox.new(root);
    profile.setObjectName("modelProfile");
    profile.addItem("tiny");
    profile.addItem("small");
    profile.addItem("medium");
    profile.onCurrentIndexChanged(profileChanged);

    const model_status = QLabel.new3("Checking model…");
    model_status.setObjectName("modelStatus");
    model_status.setWordWrap(true);

    const install = QPushButton.new5("Install", root);
    install.setObjectName("installModelButton");
    install.onClicked(installCallback);

    const remove = QPushButton.new5("Remove", root);
    remove.setObjectName("removeModelButton");
    remove.onClicked(removeCallback);

    const refresh_model = QPushButton.new5("Refresh", root);
    refresh_model.setObjectName("refreshModelButton");
    refresh_model.onClicked(refreshModelCallback);

    const model_row = QHBoxLayout.new2();
    model_row.addWidget(QLabel.new3("Model:"));
    model_row.addWidget(profile);
    model_row.addWidget(install);
    model_row.addWidget(remove);
    model_row.addWidget(refresh_model);

    const history_title = QLabel.new3("History");
    history_title.setObjectName("historyTitle");

    const history = QListWidget.new(root);
    history.setObjectName("historyList");

    const copy = QPushButton.new5("Copy", root);
    copy.setObjectName("copyHistoryButton");
    copy.onClicked(copyCallback);

    const clear = QPushButton.new5("Clear", root);
    clear.setObjectName("clearHistoryButton");
    clear.onClicked(clearCallback);

    const refresh_history = QPushButton.new5("Refresh", root);
    refresh_history.setObjectName("refreshHistoryButton");
    refresh_history.onClicked(refreshHistoryCallback);

    const history_buttons = QHBoxLayout.new2();
    history_buttons.addWidget(copy);
    history_buttons.addWidget(clear);
    history_buttons.addWidget(refresh_history);

    const status = QLabel.new3("Ready");
    status.setObjectName("statusLabel");
    status.setWordWrap(true);

    const layout = QVBoxLayout.new(root);
    layout.addWidget(title);
    layout.addSpacing(8);
    layout.addLayout(model_row);
    layout.addWidget(model_status);
    layout.addSpacing(16);
    layout.addWidget(history_title);
    layout.addWidget(history);
    layout.addLayout(history_buttons);
    layout.addWidget(status);

    var app = App{
        .allocator = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
        .root = root,
        .profile = profile,
        .model_status = model_status,
        .install = install,
        .remove = remove,
        .history = history,
        .copy = copy,
        .clear = clear,
        .status = status,
        .timer = QTimer.new2(root),
    };
    app.timer.onTimeout(pollCallback);
    active_app = &app;
    defer {
        active_app = null;
        kocr.history.freeRecords(init.gpa, app.records);
    }

    app.updateModelStatus();
    app.loadHistory();

    root.show();
    _ = QApplication.exec();
    if (app.job) |job| {
        if (job.thread) |thread| thread.join();
        app.job = null;
        job.deinit();
    }
}

pub fn main(init: std.process.Init) !void {
    try run(init);
}
