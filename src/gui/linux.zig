//! Native Qt6 window for model management, OCR history, and the shortcut daemon.
//! `kocr-gui --daemon` runs the background worker without starting Qt.

const std = @import("std");

const config = @import("config");
const core = @import("core");
const daemon = @import("daemon");
const kocr = @import("kocr");
const qt6 = @import("libqt6zig");

const QApplication = qt6.QApplication;
const QCheckBox = qt6.QCheckBox;
const QComboBox = qt6.QComboBox;
const QDialog = qt6.QDialog;
const QFileDialog = qt6.QFileDialog;
const QHBoxLayout = qt6.QHBoxLayout;
const QKeySequence = qt6.QKeySequence;
const QKeySequenceEdit = qt6.QKeySequenceEdit;
const QLabel = qt6.QLabel;
const QListWidget = qt6.QListWidget;
const QListWidgetItem = qt6.QListWidgetItem;
const QPixmap = qt6.QPixmap;
const QPushButton = qt6.QPushButton;
const QSize = qt6.QSize;
const QTimer = qt6.QTimer;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const JobKind = enum {
    install,
    remove,
    copy_image,
    save_image,
    extract,
    extract_oneline,
};

const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    kind: JobKind,
    profile: []u8,
    output_path: ?[]u8 = null,
    lines: ?[]kocr.Line = null,
    cancelled: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    error_text: ?[]u8 = null,
    thread: ?std.Thread = null,

    fn deinit(self: *Job) void {
        if (self.lines) |lines| kocr.freeLines(self.allocator, lines);
        if (self.error_text) |text| self.allocator.free(text);
        self.allocator.free(self.profile);
        if (self.output_path) |path| self.allocator.free(path);
        self.allocator.destroy(self);
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    root: QWidget,
    daemon_status: QLabel,
    daemon_toggle: QPushButton,
    daemon_running: bool = false,
    profile: QComboBox,
    model_status: QLabel,
    install: QPushButton,
    remove: QPushButton,
    copy_image: QPushButton,
    save_image: QPushButton,
    extract: QPushButton,
    extract_oneline: QPushButton,
    history: QListWidget,
    copy: QPushButton,
    delete_selected: QPushButton,
    clear: QPushButton,
    status: QLabel,
    timer: QTimer,
    history_timer: QTimer,
    history_revision: ?kocr.history.Revision = null,
    records: []kocr.history.Record = &.{},
    job: ?*Job = null,

    fn setBusy(self: *App, busy: bool) void {
        self.profile.setEnabled(!busy);
        self.install.setEnabled(!busy);
        self.remove.setEnabled(!busy);
        self.copy_image.setEnabled(!busy);
        self.save_image.setEnabled(!busy);
        self.extract.setEnabled(!busy);
        self.extract_oneline.setEnabled(!busy);
        self.updateHistoryButtons();
    }

    fn clearHistorySelection(self: *App) void {
        self.history.clearSelection();
        self.history.setCurrentRow(-1);
        self.history.clearFocus();
        self.updateHistoryButtons();
    }

    fn updateHistoryButtons(self: *App) void {
        const row = self.history.currentRow();
        const selected = row >= 0 and row < self.records.len;
        const available = self.job == null;
        self.copy.setEnabled(available and selected);
        self.delete_selected.setEnabled(available and selected);
        self.clear.setEnabled(available and self.records.len != 0);
    }

    fn selectedProfile(self: *App) ?[]u8 {
        const text = self.profile.currentText(self.allocator);
        defer self.allocator.free(text);
        return self.allocator.dupe(u8, text) catch {
            self.status.setText("Error: unable to allocate profile name");
            return null;
        };
    }

    fn updateDaemonStatus(self: *App) void {
        const running = core.daemon_process.isRunning(self.io, self.allocator, self.environ) catch false;
        self.daemon_running = running;
        self.daemon_status.setText(if (running) "Daemon: running" else "Daemon: stopped");
        self.daemon_toggle.setText(if (running) "Stop" else "Start");
    }

    fn toggleDaemon(self: *App) void {
        if (self.daemon_running) {
            core.daemon_process.stop(self.io, self.allocator, self.environ) catch |err| {
                var message: [256]u8 = undefined;
                self.status.setText(std.fmt.bufPrint(&message, "Daemon stop failed: {s}", .{@errorName(err)}) catch "Daemon stop failed");
                return;
            };
            self.status.setText("Daemon stopped");
        } else {
            const started = core.daemon_process.ensureRunning(self.io, self.allocator, self.environ) catch |err| {
                var message: [256]u8 = undefined;
                self.status.setText(std.fmt.bufPrint(&message, "Daemon start failed: {s}", .{@errorName(err)}) catch "Daemon start failed");
                return;
            };
            self.status.setText(if (started) "Daemon started" else "Daemon already running");
        }
        self.updateDaemonStatus();
    }

    fn updateModelStatus(self: *App) void {
        if (self.job != null) return;
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

    fn loadSelection(self: *App) void {
        var parsed = config.load(self.allocator, self.io, self.environ) catch |err| {
            var message: [256]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&message, "Config error: {s}", .{@errorName(err)}) catch "Config error");
            return;
        };
        defer parsed.deinit();
        const selected = parsed.value.models.select orelse return;
        const index = self.profile.findText(selected);
        if (index >= 0) self.profile.setCurrentIndex(index);
    }

    fn saveSelection(self: *App) void {
        const profile = self.profile.currentText(self.allocator);
        defer self.allocator.free(profile);
        var parsed = config.load(self.allocator, self.io, self.environ) catch |err| {
            var message: [256]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&message, "Config error: {s}", .{@errorName(err)}) catch "Config error");
            return;
        };
        defer parsed.deinit();
        parsed.value.models.select = profile;
        config.save(self.allocator, self.io, self.environ, parsed.value) catch |err| {
            var message: [256]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&message, "Could not save config: {s}", .{@errorName(err)}) catch "Could not save config");
        };
    }

    fn loadHistory(self: *App) void {
        const was_empty = self.records.len == 0;
        const selected_id: ?i64 = blk: {
            const row = self.history.currentRow();
            if (row < 0 or row >= self.records.len) break :blk null;
            break :blk self.records[@intCast(row)].id;
        };
        kocr.history.freeRecords(self.allocator, self.records);
        self.records = &.{};
        self.history.clear();

        self.records = kocr.history.recent(self.io, self.allocator, self.environ, 200) catch |err| {
            var message: [256]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&message, "History error: {s}", .{@errorName(err)}) catch "History error");
            return;
        };
        for (self.records) |record| {
            const item = QListWidgetItem.new2("");
            const row = QWidget.new2();
            const row_layout = QHBoxLayout.new(row);
            row_layout.setContentsMargins(8, 0, 8, 0);
            row_layout.setSpacing(8);
            row.setFixedHeight(48);
            const time = QLabel.new3(formatTime(record.created_at));
            time.setFixedWidth(140);
            time.setAttribute2(qt6.qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);
            row_layout.addWidget(time);

            switch (record.content) {
                .text => |text| {
                    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
                    const content = QLabel.new3(text[0..@min(end, 160)]);
                    content.setAttribute2(qt6.qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);
                    row_layout.addWidget2(content, 1);
                    item.setToolTip(text);
                },
                .image => |path| {
                    const content = QLabel.new3("");
                    content.setFixedSize2(36, 36);
                    content.setAttribute2(qt6.qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);
                    const pixmap = QPixmap.new4(path);
                    defer pixmap.delete();
                    if (!pixmap.isNull()) {
                        const thumbnail = pixmap.scaled4(
                            36,
                            36,
                            qt6.qnamespace_enums.AspectRatioMode.KeepAspectRatio,
                            qt6.qnamespace_enums.TransformationMode.SmoothTransformation,
                        );
                        defer thumbnail.delete();
                        content.setPixmap(thumbnail);
                    }
                    row_layout.addWidget(content);
                    row_layout.addStretch();
                    const tooltip = imageTooltip(self.allocator, path) catch path;
                    defer if (tooltip.ptr != path.ptr) self.allocator.free(tooltip);
                    item.setToolTip(tooltip);
                },
            }
            row.setAttribute2(qt6.qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);
            self.history.addItem2(item);
            self.history.setItemWidget(item, row);
            item.setSizeHint(QSize.new4(0, 48));
        }
        if (self.records.len == 0) {
            self.status.setText("No history yet");
        } else {
            if (was_empty) self.status.setText("Ready");
            if (selected_id) |id| {
                for (self.records, 0..) |record, index| {
                    if (record.id == id) {
                        self.history.setCurrentRow(@intCast(index));
                        break;
                    }
                }
            }
        }
        self.updateHistoryButtons();
    }

    fn pollHistory(self: *App) void {
        const revision = kocr.history.revision(self.io, self.allocator, self.environ) catch return;
        if (self.history_revision) |current| {
            if (current.count == revision.count and current.max_id == revision.max_id) return;
        }
        self.history_revision = revision;
        self.loadHistory();
    }

    fn start(self: *App, kind: JobKind, output_path: ?[]const u8) void {
        if (self.job != null) return;
        const profile = self.selectedProfile() orelse return;
        const owned_path = if (output_path) |path| self.allocator.dupe(u8, path) catch {
            self.allocator.free(profile);
            self.status.setText("Error: unable to allocate output path");
            return;
        } else null;

        const job = self.allocator.create(Job) catch {
            self.allocator.free(profile);
            if (owned_path) |path| self.allocator.free(path);
            self.status.setText("Error: unable to allocate job");
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .kind = kind,
            .profile = profile,
            .output_path = owned_path,
        };
        self.job = job;
        self.setBusy(true);
        self.status.setText(switch (kind) {
            .install => "Installing model…",
            .remove => "Removing model…",
            .copy_image, .save_image => "Capturing region…",
            .extract, .extract_oneline => "Capturing and recognizing…",
        });
        job.thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            self.job = null;
            self.setBusy(false);
            self.status.setText("Error: unable to start worker thread");
            job.deinit();
            return;
        };
        self.timer.start(50);
    }

    fn startModel(self: *App, kind: JobKind) void {
        self.start(kind, null);
    }

    fn capturePath(self: *App) ?[]u8 {
        const now = std.Io.Clock.real.now(self.io);
        return std.fmt.allocPrint(self.allocator, "/tmp/kocr-{d}.png", .{now.nanoseconds}) catch {
            self.status.setText("Error: unable to allocate capture path");
            return null;
        };
    }

    fn poll(self: *App) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        self.timer.stop();
        if (job.thread) |thread| thread.join();

        const error_text = job.error_text;
        job.error_text = null;
        const kind = job.kind;
        const cancelled = job.cancelled;
        const output_path = job.output_path;
        const lines = job.lines;
        job.lines = null;
        job.output_path = null;
        self.job = null;
        self.setBusy(false);

        if (error_text) |text| {
            self.status.setText(text);
            self.allocator.free(text);
            if (kind != .save_image) {
                if (output_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            }
        } else if (cancelled) {
            self.status.setText("Capture cancelled");
        } else switch (kind) {
            .install => {
                self.updateModelStatus();
                self.status.setText("Model installed");
            },
            .remove => {
                self.updateModelStatus();
                self.status.setText("Model removed");
            },
            .copy_image => {
                if (output_path) |path| {
                    const pixmap = QPixmap.new4(path);
                    defer pixmap.delete();
                    QApplication.clipboard().setPixmap(pixmap);
                    kocr.history.appendImage(self.io, self.allocator, self.environ, path) catch {};
                    self.loadHistory();
                    self.status.setText("Screenshot copied");
                    std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                }
            },
            .save_image => {
                if (output_path) |temporary| {
                    const destination = QFileDialog.getSaveFileName4(
                        self.allocator,
                        self.root,
                        "Save screenshot",
                        "",
                        "PNG (*.png)",
                    );
                    defer self.allocator.free(destination);
                    if (destination.len == 0) {
                        self.status.setText("Save cancelled");
                        std.Io.Dir.cwd().deleteFile(self.io, temporary) catch {};
                    } else {
                        var saved = true;
                        std.Io.Dir.copyFileAbsolute(temporary, destination, self.io, .{}) catch |err| {
                            var message: [256]u8 = undefined;
                            self.status.setText(std.fmt.bufPrint(&message, "Save failed: {s}", .{@errorName(err)}) catch "Save failed");
                            saved = false;
                        };
                        if (saved) {
                            kocr.history.appendImage(self.io, self.allocator, self.environ, destination) catch {};
                            self.loadHistory();
                            self.status.setText("Screenshot saved");
                        }
                        std.Io.Dir.cwd().deleteFile(self.io, temporary) catch {};
                    }
                }
            },
            .extract, .extract_oneline => {
                if (lines) |recognized| {
                    const text = linesToText(self.allocator, recognized, kind == .extract_oneline) catch null;
                    if (text) |result| {
                        defer self.allocator.free(result);
                        QApplication.clipboard().setText(result);
                        if (result.len != 0) {
                            kocr.history.appendText(self.io, self.allocator, self.environ, result) catch {};
                        }
                        self.loadHistory();
                        self.status.setText(if (result.len == 0) "No text found" else "Text copied");
                    } else {
                        self.status.setText("Error: unable to format text");
                    }
                    kocr.freeLines(self.allocator, recognized);
                }
                if (output_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            },
        }
        if (lines != null and kind != .extract and kind != .extract_oneline) {
            kocr.freeLines(self.allocator, lines.?);
        }
        if (output_path) |path| self.allocator.free(path);
        job.deinit();
    }

    fn copySelected(self: *App) void {
        const row = self.history.currentRow();
        if (row < 0 or row >= self.records.len) {
            self.status.setText("Select a history entry first");
            return;
        }
        switch (self.records[@intCast(row)].content) {
            .text => |text| {
                QApplication.clipboard().setText(text);
                self.status.setText("Copied to clipboard");
            },
            .image => |path| {
                const pixmap = QPixmap.new4(path);
                defer pixmap.delete();
                QApplication.clipboard().setPixmap(pixmap);
                self.status.setText("Image copied to clipboard");
            },
        }
    }

    fn deleteSelected(self: *App) void {
        const row = self.history.currentRow();
        if (row < 0 or row >= self.records.len) {
            self.status.setText("Select a history entry first");
            return;
        }
        const id = self.records[@intCast(row)].id;
        kocr.history.delete(self.io, self.allocator, self.environ, id) catch |err| {
            var message: [256]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&message, "Delete failed: {s}", .{@errorName(err)}) catch "Delete failed");
            return;
        };
        self.loadHistory();
        self.status.setText("History entry deleted");
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
                finishError(job, err);
                return;
            };
        },
        .remove => {
            kocr.downloader.remove(job.io, job.allocator, job.environ, job.profile) catch |err| {
                finishError(job, err);
                return;
            };
        },
        .copy_image, .save_image, .extract, .extract_oneline => {
            const path = job.output_path orelse {
                finishError(job, error.InvalidOutputPath);
                return;
            };
            const capture = core.captureRegion(job.allocator, job.io, path) catch |err| {
                finishError(job, err);
                return;
            };
            if (capture == .cancelled) {
                job.cancelled = true;
                job.done.store(true, .release);
                return;
            }
            if (job.kind == .extract or job.kind == .extract_oneline) {
                const model_dir = kocr.paths.profileDir(job.io, job.allocator, job.environ, job.profile) catch |err| {
                    finishError(job, err);
                    return;
                };
                defer job.allocator.free(model_dir);
                job.lines = kocr.recognizeFile(job.allocator, job.io, path, .{ .model_dir = model_dir }) catch |err| {
                    finishError(job, err);
                    return;
                };
            }
        },
    }
    job.done.store(true, .release);
}

fn finishError(job: *Job, err: anyerror) void {
    setError(job, err);
    job.done.store(true, .release);
}

fn linesToText(allocator: std.mem.Allocator, lines: []const kocr.Line, one_line: bool) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (lines, 0..) |line, index| {
        if (index != 0) try text.append(allocator, if (one_line) ' ' else '\n');
        try text.appendSlice(allocator, line.text);
    }
    return text.toOwnedSlice(allocator);
}

fn setError(job: *Job, err: anyerror) void {
    job.error_text = std.fmt.allocPrint(job.allocator, "Error: {s}", .{@errorName(err)}) catch null;
}

fn imageTooltip(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "<img src=\"file://{s}\" width=\"320\">",
        .{path},
    );
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

const SettingsState = struct {
    app: *App,
    dialog: QDialog,
    copy_edit: QKeySequenceEdit,
    save_edit: QKeySequenceEdit,
    ocr_edit: QKeySequenceEdit,
    oneline_edit: QKeySequenceEdit,
    hints: [4]QLabel,
    autostart: QCheckBox,

    fn clearShortcutFocus(self: *SettingsState) void {
        self.copy_edit.clearFocus();
        self.save_edit.clearFocus();
        self.ocr_edit.clearFocus();
        self.oneline_edit.clearFocus();
        self.dialog.setFocus();
    }
};

var settings_state: ?*SettingsState = null;

fn openSettings(app: *App) void {
    if (settings_state != null) return;
    const state = app.allocator.create(SettingsState) catch return;
    var parsed = config.load(app.allocator, app.io, app.environ) catch |err| {
        var message: [256]u8 = undefined;
        app.status.setText(std.fmt.bufPrint(&message, "Config error: {s}", .{@errorName(err)}) catch "Config error");
        app.allocator.destroy(state);
        return;
    };
    defer parsed.deinit();

    const dialog = QDialog.new(app.root);
    dialog.setWindowTitle("kocr gui settings");
    dialog.resize(560, 320);
    dialog.onMousePressEvent(settingsDialogPressed);
    const layout = QVBoxLayout.new(dialog);
    layout.addWidget(QLabel.new3("Shortcuts"));
    const rows = [_]struct { label: []const u8, value: ?[]const u8 }{
        .{ .label = "Copy image", .value = parsed.value.shortcuts.copy },
        .{ .label = "Save image", .value = parsed.value.shortcuts.save },
        .{ .label = "Extract text", .value = parsed.value.shortcuts.ocr },
        .{ .label = "One line", .value = parsed.value.shortcuts.oneline },
    };
    var editors: [4]QKeySequenceEdit = undefined;
    var hints: [4]QLabel = undefined;
    for (rows, 0..) |row, index| {
        const line = QHBoxLayout.new2();
        const label = QLabel.new3(row.label);
        label.setFixedWidth(140);
        line.addWidget(label);
        editors[index] = QKeySequenceEdit.new(dialog);
        editors[index].setObjectName("shortcutEditor");
        editors[index].setClearButtonEnabled(true);
        if (row.value) |value| editors[index].setKeySequence(QKeySequence.fromString(value));
        line.addWidget2(editors[index], 1);
        hints[index] = QLabel.new5("Press shortcut…", editors[index]);
        var hint_palette = hints[index].palette();
        const placeholder_color = hint_palette.color2(qt6.qpalette_enums.ColorRole.PlaceholderText);
        hint_palette.setColor2(qt6.qpalette_enums.ColorRole.WindowText, placeholder_color);
        hints[index].setPalette(hint_palette);
        hints[index].setStyleSheet("background: transparent; padding-left: 6px;");
        hints[index].setAttribute2(qt6.qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);
        hints[index].setVisible(row.value == null or row.value.?.len == 0);
        editors[index].onResizeEvent(shortcutResized);
        layout.addLayout(line);
    }
    layout.addSpacing(12);
    layout.addWidget(QLabel.new3("Daemon"));
    const autostart = QCheckBox.new4("Start daemon at login", dialog);
    autostart.setChecked(core.autostart.enabled(app.io, app.allocator, app.environ) catch false);
    layout.addWidget(autostart);

    const buttons = QHBoxLayout.new2();
    buttons.addStretch();
    const cancel = QPushButton.new5("Cancel", dialog);
    const save = QPushButton.new5("Save", dialog);
    cancel.onClicked(cancelSettings);
    save.onClicked(saveSettings);
    buttons.addWidget(cancel);
    buttons.addWidget(save);
    layout.addLayout(buttons);

    state.* = .{
        .app = app,
        .dialog = dialog,
        .copy_edit = editors[0],
        .save_edit = editors[1],
        .ocr_edit = editors[2],
        .oneline_edit = editors[3],
        .hints = hints,
        .autostart = autostart,
    };
    settings_state = state;
    editors[0].onKeySequenceChanged(shortcutChanged);
    editors[1].onKeySequenceChanged(shortcutChanged);
    editors[2].onKeySequenceChanged(shortcutChanged);
    editors[3].onKeySequenceChanged(shortcutChanged);
    _ = dialog.exec();
    settings_state = null;
    dialog.delete();
    app.allocator.destroy(state);
}

fn saveSettings(_: QPushButton) callconv(.c) void {
    const state = settings_state orelse return;
    const allocator = state.app.allocator;
    const copy = state.copy_edit.keySequence().toString(allocator);
    defer allocator.free(copy);
    const save = state.save_edit.keySequence().toString(allocator);
    defer allocator.free(save);
    const ocr = state.ocr_edit.keySequence().toString(allocator);
    defer allocator.free(ocr);
    const oneline = state.oneline_edit.keySequence().toString(allocator);
    defer allocator.free(oneline);

    var parsed = config.load(allocator, state.app.io, state.app.environ) catch |err| {
        var message: [256]u8 = undefined;
        state.app.status.setText(std.fmt.bufPrint(&message, "Config error: {s}", .{@errorName(err)}) catch "Config error");
        return;
    };
    defer parsed.deinit();
    parsed.value.shortcuts.copy = copy;
    parsed.value.shortcuts.save = save;
    parsed.value.shortcuts.ocr = ocr;
    parsed.value.shortcuts.oneline = oneline;
    config.save(allocator, state.app.io, state.app.environ, parsed.value) catch |err| {
        var message: [256]u8 = undefined;
        state.app.status.setText(std.fmt.bufPrint(&message, "Could not save config: {s}", .{@errorName(err)}) catch "Could not save config");
        return;
    };
    const daemon_executable = std.process.executablePathAlloc(state.app.io, allocator) catch "";
    defer if (daemon_executable.len != 0) allocator.free(daemon_executable);

    core.autostart.set(
        state.app.io,
        allocator,
        state.app.environ,
        state.autostart.isChecked(),
        daemon_executable,
    ) catch |err| {
        var message: [256]u8 = undefined;
        state.app.status.setText(std.fmt.bufPrint(&message, "Could not update autostart: {s}", .{@errorName(err)}) catch "Could not update autostart");
    };
    state.app.status.setText("Settings saved");
    state.dialog.accept();
}

fn cancelSettings(_: QPushButton) callconv(.c) void {
    if (settings_state) |state| state.dialog.reject();
}

fn pollCallback(_: QTimer) callconv(.c) void {
    if (active_app) |app| app.poll();
}

fn historyPollCallback(_: QTimer) callconv(.c) void {
    if (active_app) |app| {
        app.pollHistory();
        app.updateModelStatus();
        app.updateDaemonStatus();
    }
}

fn rootMousePressed(_: QWidget, _: qt6.QMouseEvent) callconv(.c) void {
    if (active_app) |app| app.clearHistorySelection();
}

fn shortcutResized(editor: QKeySequenceEdit, _: qt6.QResizeEvent) callconv(.c) void {
    const state = settings_state orelse return;
    const editors = [_]QKeySequenceEdit{ state.copy_edit, state.save_edit, state.ocr_edit, state.oneline_edit };
    for (editors, 0..) |candidate, index| {
        if (candidate.ptr == editor.ptr) {
            state.hints[index].setGeometry(0, 0, editor.width(), editor.height());
            break;
        }
    }
}

fn shortcutChanged(editor: QKeySequenceEdit, sequence: QKeySequence) callconv(.c) void {
    const state = settings_state orelse return;
    const text = sequence.toString(state.app.allocator);
    defer state.app.allocator.free(text);
    const empty = text.len == 0;
    const editors = [_]QKeySequenceEdit{ state.copy_edit, state.save_edit, state.ocr_edit, state.oneline_edit };
    for (editors, 0..) |candidate, index| {
        if (candidate.ptr == editor.ptr) {
            state.hints[index].setVisible(empty);
            break;
        }
    }
}

fn settingsDialogPressed(_: QDialog, _: qt6.QMouseEvent) callconv(.c) void {
    if (settings_state) |state| state.clearShortcutFocus();
}

fn daemonToggleCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.toggleDaemon();
}

fn settingsCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| openSettings(app);
}

fn installCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.startModel(.install);
}

fn removeCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.startModel(.remove);
}

fn profileChanged(_: QComboBox, _: i32) callconv(.c) void {
    if (active_app) |app| {
        app.updateModelStatus();
        app.saveSelection();
    }
}

fn copyImageCallback(_: QPushButton) callconv(.c) void {
    const app = active_app orelse return;
    const path = app.capturePath() orelse return;
    defer app.allocator.free(path);
    app.start(.copy_image, path);
}

fn saveImageCallback(_: QPushButton) callconv(.c) void {
    const app = active_app orelse return;
    const path = app.capturePath() orelse return;
    defer app.allocator.free(path);
    app.start(.save_image, path);
}

fn extractCallback(_: QPushButton) callconv(.c) void {
    const app = active_app orelse return;
    const path = app.capturePath() orelse return;
    defer app.allocator.free(path);
    app.start(.extract, path);
}

fn extractOnelineCallback(_: QPushButton) callconv(.c) void {
    const app = active_app orelse return;
    const path = app.capturePath() orelse return;
    defer app.allocator.free(path);
    app.start(.extract_oneline, path);
}

fn historySelectionChanged(_: QListWidget, _: i32) callconv(.c) void {
    if (active_app) |app| app.updateHistoryButtons();
}

fn copyCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.copySelected();
}

fn deleteCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.deleteSelected();
}

fn clearCallback(_: QPushButton) callconv(.c) void {
    if (active_app) |app| app.clearHistory();
}

fn closeCallback(_: QWidget, _: qt6.QCloseEvent) callconv(.c) void {
    if (active_app) |app| {
        app.timer.stop();
        app.history_timer.stop();
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
    root.setWindowTitle("kocr gui");
    root.resize(760, 560);
    root.onCloseEvent(closeCallback);
    root.onMousePressEvent(rootMousePressed);

    const daemon_status = QLabel.new3("Daemon: checking…");
    daemon_status.setObjectName("daemonStatus");
    const daemon_toggle = QPushButton.new5("Start daemon", root);
    daemon_toggle.setObjectName("daemonToggleButton");
    daemon_toggle.onClicked(daemonToggleCallback);
    const settings = QPushButton.new5("Settings…", root);
    settings.setObjectName("settingsButton");
    settings.onClicked(settingsCallback);
    const header = QHBoxLayout.new2();
    header.addWidget(daemon_status);
    header.addWidget(daemon_toggle);
    header.addStretch();
    header.addWidget(settings);

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

    const copy_image = QPushButton.new5("Copy image", root);
    copy_image.setObjectName("copyImageButton");
    copy_image.onClicked(copyImageCallback);

    const save_image = QPushButton.new5("Save image", root);
    save_image.setObjectName("saveImageButton");
    save_image.onClicked(saveImageCallback);

    const extract = QPushButton.new5("Extract text", root);
    extract.setObjectName("extractTextButton");
    extract.onClicked(extractCallback);

    const extract_oneline = QPushButton.new5("One line", root);
    extract_oneline.setObjectName("extractOneLineButton");
    extract_oneline.onClicked(extractOnelineCallback);

    const action_row = QHBoxLayout.new2();
    action_row.addWidget(copy_image);
    action_row.addWidget(save_image);
    action_row.addWidget(extract);
    action_row.addWidget(extract_oneline);

    const model_row = QHBoxLayout.new2();
    model_row.addWidget(QLabel.new3("Model:"));
    model_row.addWidget(profile);
    model_row.addWidget(install);
    model_row.addWidget(remove);

    const history_title = QLabel.new3("History");
    history_title.setObjectName("historyTitle");

    const history = QListWidget.new(root);
    history.setObjectName("historyList");
    history.setToolTipDuration(10000);
    history.setUniformItemSizes(true);
    history.setSpacing(0);
    history.setStyleSheet(
        \\QListWidget::item {
        \\    margin: 0px;
        \\    padding: 0px;
        \\    min-height: 48px;
        \\    max-height: 48px;
        \\    border-radius: 4px;
        \\}
        \\QListWidget::item:hover {
        \\    background: palette(midlight);
        \\}
        \\QListWidget::item:selected {
        \\    background: palette(highlight);
        \\    color: palette(highlighted-text);
        \\}
    );
    history.onCurrentRowChanged(historySelectionChanged);

    const copy = QPushButton.new5("Copy", root);
    copy.setObjectName("copyHistoryButton");
    copy.onClicked(copyCallback);

    const delete_selected = QPushButton.new5("Delete", root);
    delete_selected.setObjectName("deleteHistoryButton");
    delete_selected.onClicked(deleteCallback);

    const clear = QPushButton.new5("Clear all", root);
    clear.setObjectName("clearHistoryButton");
    clear.onClicked(clearCallback);

    const history_buttons = QHBoxLayout.new2();
    history_buttons.addWidget(copy);
    history_buttons.addWidget(delete_selected);
    history_buttons.addWidget(clear);

    const status = QLabel.new3("Ready");
    status.setObjectName("statusLabel");
    status.setWordWrap(true);

    const layout = QVBoxLayout.new(root);
    layout.addLayout(header);
    layout.addSpacing(8);
    layout.addLayout(action_row);
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
        .daemon_status = daemon_status,
        .daemon_toggle = daemon_toggle,
        .profile = profile,
        .model_status = model_status,
        .install = install,
        .remove = remove,
        .copy_image = copy_image,
        .save_image = save_image,
        .extract = extract,
        .extract_oneline = extract_oneline,
        .history = history,
        .copy = copy,
        .delete_selected = delete_selected,
        .clear = clear,
        .status = status,
        .timer = QTimer.new2(root),
        .history_timer = QTimer.new2(root),
    };
    app.timer.onTimeout(pollCallback);
    app.history_timer.setInterval(1000);
    app.history_timer.onTimeout(historyPollCallback);
    app.history_timer.start(1000);
    active_app = &app;
    defer {
        active_app = null;
        kocr.history.freeRecords(init.gpa, app.records);
    }

    app.loadSelection();
    app.updateModelStatus();
    app.updateDaemonStatus();
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
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) return daemon.run(init);
    }
    try run(init);
}
