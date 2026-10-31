#![cfg_attr(windows, windows_subsystem = "windows")]
//! Desktop app for capture, OCR models, shortcuts, and the system tray.

#[macro_use]
extern crate rust_i18n;

i18n!("locales", fallback = "en");

mod history;
mod preferences;
mod tray;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

use chrono::{Local, TimeZone};
use eframe::egui;
use history::{Content as StoredContent, History, Record as StoredRecord};
use kocr_config::{Config, Key, Modifiers as ConfigModifiers, parse_shortcut};
use kocr_model::Progress;
use preferences::{CloseAction, Preferences};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Page {
    Capture,
    Models,
    Shortcuts,
    Preferences,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ShortcutField {
    Copy,
    Ocr,
    Oneline,
}

struct CaptureOutput {
    text: Option<String>,
    png: Vec<u8>,
}

enum RecordContent {
    Text(String),
    Image(PathBuf),
}

struct CaptureRecord {
    id: i64,
    content: RecordContent,
    time: String,
}

enum CopyAction {
    Text(String),
    Image(PathBuf),
}

#[derive(Clone)]
struct ModelRow {
    name: String,
    installed: bool,
}

enum Event {
    Models(Result<Vec<ModelRow>, String>),
    Shortcuts(String),
    Progress(Progress),
    Installed(Result<String, String>),
    Captured(Result<CaptureOutput, String>),
    ShortcutCapture(bool, bool),
}

struct KocrApp {
    ctx: egui::Context,
    tx: Sender<Event>,
    rx: Receiver<Event>,
    page: Page,
    config: Config,
    models: Vec<ModelRow>,
    load_error: Option<String>,
    preferences: Preferences,
    installing: bool,
    font_size_draft: f32,
    progress: Option<Progress>,
    capturing: bool,
    confirm_clear: bool,
    history_limit_draft: usize,
    confirm_history_apply: bool,
    history_store: Option<History>,
    history: Vec<CaptureRecord>,
    texture_cache: HashMap<i64, egui::TextureHandle>,
    status: String,
    copy: String,
    ocr: String,
    oneline: String,
    shortcut_recording: Option<ShortcutField>,
    tray: Option<tray::Tray>,
    tray_ready: bool,
    exit_requested: bool,
    shortcuts_status: String,
}

impl KocrApp {
    fn new(ctx: egui::Context, preferences: Preferences) -> Self {
        let (config, load_error) = match Config::load() {
            Ok(config) => (config, None),
            Err(error) => (Config::default(), Some(error.to_string())),
        };
        let models = Vec::new();
        let copy = config.shortcut.copy.clone().unwrap_or_default();
        let ocr = config.shortcut.ocr.clone().unwrap_or_default();
        let oneline = config.shortcut.oneline.clone().unwrap_or_default();
        let mut status = load_error
            .clone()
            .unwrap_or_else(|| selected_model_status(&config));

        let (tx, rx) = mpsc::channel();
        let worker_tx = tx.clone();
        let worker_ctx = ctx.clone();
        thread::spawn(move || {
            let result = load_models();
            let _ = worker_tx.send(Event::Models(result));
            worker_ctx.request_repaint();
        });

        let shortcut_tx = tx.clone();
        let shortcut_ctx = ctx.clone();
        thread::spawn(move || {
            let capture_tx = shortcut_tx.clone();
            let capture_ctx = shortcut_ctx.clone();
            let result = kocr_shortcuts::run(move |recognize, oneline| {
                let _ = capture_tx.send(Event::ShortcutCapture(recognize, oneline));
                capture_ctx.request_repaint();
                Ok::<(), String>(())
            });
            if let Err(error) = result {
                let _ = shortcut_tx.send(Event::Shortcuts(error.to_string()));
                shortcut_ctx.request_repaint();
            }
        });

        let (tray, tray_error) = match tray::Tray::new(ctx.clone()) {
            Ok(tray) => (Some(tray), None),
            Err(error) => (None, Some(t!("tray_failed", err = error).to_string())),
        };
        if let Some(error) = tray_error {
            status = error;
        }
        let font_size_draft = preferences.font_size;
        let history_limit_draft = preferences.history_limit;
        let (history_store, history, history_error) = load_history(preferences.history_limit);
        if let Some(error) = history_error {
            status = error;
        }

        Self {
            ctx,
            tx,
            rx,
            page: Page::Capture,
            config,
            models,
            load_error,
            preferences,
            installing: false,
            font_size_draft,
            progress: None,
            capturing: false,
            confirm_clear: false,
            history_limit_draft,
            confirm_history_apply: false,
            history_store,
            history,
            texture_cache: HashMap::new(),
            status,
            copy,
            ocr,
            oneline,
            shortcut_recording: None,
            tray,
            tray_ready: false,
            exit_requested: false,
            shortcuts_status: t!("shortcuts_running").to_string(),
        }
    }

    fn poll(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            match event {
                Event::Models(result) => match result {
                    Ok(models) => self.models = models,
                    Err(error) => self.status = error,
                },
                Event::Progress(progress) => {
                    self.progress = Some(progress);
                }
                Event::Installed(result) => {
                    self.installing = false;
                    self.progress = None;
                    self.status = match result {
                        Ok(name) => match self.refresh_models() {
                            Ok(()) => t!("installed", name = name).to_string(),
                            Err(error) => error,
                        },
                        Err(error) => error,
                    };
                }
                Event::Shortcuts(status) => {
                    self.shortcuts_status = status;
                }
                Event::ShortcutCapture(recognize, oneline) => {
                    self.capture(recognize, oneline);
                }
                Event::Captured(result) => {
                    self.capturing = false;
                    match result {
                        Ok(output) => {
                            let now = Local::now();
                            let created_at = now.timestamp();
                            let time = now.format("%H:%M:%S").to_string();
                            match output.text {
                                Some(text) => {
                                    if !text.is_empty() {
                                        let id = self.store_text(created_at, &text).unwrap_or_else(
                                            |error| {
                                                self.status = error;
                                                -1
                                            },
                                        );
                                        self.history.insert(
                                            0,
                                            CaptureRecord {
                                                id,
                                                content: RecordContent::Text(text),
                                                time,
                                            },
                                        );
                                        self.trim_history();
                                    }
                                    self.status = t!("status_text_copied").to_string();
                                }
                                None => {
                                    let (id, path) = self
                                        .store_image(created_at, &output.png)
                                        .unwrap_or_else(|error| {
                                            self.status = error;
                                            (-1, PathBuf::new())
                                        });
                                    self.history.insert(
                                        0,
                                        CaptureRecord {
                                            id,
                                            content: RecordContent::Image(path),
                                            time,
                                        },
                                    );
                                    self.trim_history();
                                    self.status = t!("status_png_copied").to_string();
                                }
                            }
                        }
                        Err(error) => self.status = error,
                    }
                }
            }
        }
    }

    fn store_text(&self, created_at: i64, text: &str) -> Result<i64, String> {
        self.history_store
            .as_ref()
            .map_or(Ok(-1), |store| store.insert_text(created_at, text))
    }

    fn store_image(&self, created_at: i64, png: &[u8]) -> Result<(i64, PathBuf), String> {
        self.history_store
            .as_ref()
            .map_or(Ok((-1, PathBuf::new())), |store| {
                store.insert_image(created_at, png)
            })
    }

    fn trim_history(&mut self) {
        self.enforce_history_limit(self.preferences.history_limit);
    }

    fn enforce_history_limit(&mut self, limit: usize) -> bool {
        if let Some(store) = &self.history_store {
            match store.prune(limit) {
                Ok(paths) => history::remove_files(paths),
                Err(error) => {
                    self.status = error;
                    return false;
                }
            }
        }

        let mut removed = Vec::new();
        while self.history.len() > limit {
            if let Some(record) = self.history.pop() {
                removed.push(record.id);
            }
        }
        for id in removed {
            self.texture_cache.remove(&id);
        }
        true
    }

    fn apply_history_retention(&mut self, limit: usize) {
        let current = self.history.len();
        if !self.enforce_history_limit(limit) {
            return;
        }
        self.preferences.history_limit = limit;
        if self.save_preferences() {
            self.status = if current > limit {
                t!("status_history_cleaned", limit = limit).to_string()
            } else {
                t!("status_history_limit", limit = limit).to_string()
            };
        }
    }

    fn remove_record(&mut self, id: i64) {
        if let Some(store) = &self.history_store {
            match store.delete(id) {
                Ok(path) => {
                    if let Some(path) = path {
                        history::remove_files([path]);
                    }
                }
                Err(error) => self.status = error,
            }
        }
        self.texture_cache.remove(&id);
        self.history.retain(|record| record.id != id);
    }

    fn clear_history(&mut self) {
        if let Some(store) = &self.history_store {
            match store.clear() {
                Ok(paths) => history::remove_files(paths),
                Err(error) => {
                    self.status = error;
                    return;
                }
            }
        }
        self.texture_cache.clear();
        self.history.clear();
    }

    fn refresh_models(&mut self) -> Result<(), String> {
        self.config = Config::load().map_err(|error| error.to_string())?;
        self.load_error = None;
        self.models = load_models()?;
        Ok(())
    }

    fn set_active_model(&mut self, name: Option<String>) {
        let mut config = self.config.clone();
        config.models.select = name;
        self.status = match config.save() {
            Ok(()) => {
                self.config = config;
                selected_model_status(&self.config)
            }
            Err(error) => error.to_string(),
        };
    }

    fn uninstall(&mut self, name: &str) {
        self.status = match kocr_model::uninstall(name) {
            Ok(name) => match self.refresh_models() {
                Ok(()) => t!("uninstalled", name = name).to_string(),
                Err(error) => error,
            },
            Err(error) => error.to_string(),
        };
    }

    fn install(&mut self, name: &str) {
        if self.installing {
            return;
        }

        self.installing = true;
        self.progress = Some(Progress {
            downloaded: 0,
            total: None,
        });
        self.status = t!("installing", name = name).to_string();

        let name = name.to_owned();
        let tx = self.tx.clone();
        let ctx = self.ctx.clone();
        thread::spawn(move || {
            let result = kocr_model::install(&name, None, |progress| {
                let _ = tx.send(Event::Progress(progress));
                ctx.request_repaint();
            })
            .map(|installed| installed.name)
            .map_err(|error| error.to_string());
            let _ = tx.send(Event::Installed(result));
            ctx.request_repaint();
        });
    }

    fn capture(&mut self, recognize: bool, oneline: bool) {
        if self.capturing {
            return;
        }
        self.capturing = true;
        self.status = t!("status_capturing").to_string();

        let tx = self.tx.clone();
        let ctx = self.ctx.clone();
        thread::spawn(move || {
            let result = kocr_core::capture::run(None, recognize, oneline)
                .map(|result| CaptureOutput {
                    text: result.text,
                    png: result.png,
                })
                .map_err(|error| error.to_string());
            let _ = tx.send(Event::Captured(result));
            ctx.request_repaint();
        });
    }

    fn save(&mut self) {
        if let Some(error) = &self.load_error {
            self.status = error.clone();
            return;
        }

        let copy = self.copy.trim();
        let ocr = self.ocr.trim();
        let oneline = self.oneline.trim();
        if let Err(error) =
            validate_shortcuts(&[("copy", copy), ("ocr", ocr), ("one line", oneline)])
        {
            self.status = error;
            return;
        }

        let mut config = self.config.clone();
        config.shortcut.copy = Some(copy.to_owned());
        config.shortcut.ocr = Some(ocr.to_owned());
        config.shortcut.oneline = Some(oneline.to_owned());
        if let Err(error) = config.save() {
            self.status = error.to_string();
        } else {
            self.config = config;
        }
    }

    fn poll_tray(&mut self, ctx: &egui::Context) {
        #[cfg(target_os = "linux")]
        let mut tray_failed = false;
        for _ in 0..8 {
            let Some(event) = self.tray.as_ref().and_then(tray::Tray::try_recv) else {
                break;
            };
            match event {
                tray::Event::Ready => self.tray_ready = true,
                tray::Event::Show => {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                }
                tray::Event::Exit => {
                    self.exit_requested = true;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
                #[cfg(target_os = "linux")]
                tray::Event::Failed(error) => {
                    self.status = t!("tray_failed", err = error).to_string();
                    self.tray_ready = false;
                    tray_failed = true;
                }
            }
        }
        #[cfg(target_os = "linux")]
        if tray_failed {
            self.tray = None;
        }
    }

    fn handle_close(&self, ctx: &egui::Context) {
        if self.exit_requested
            || self.preferences.close_action != CloseAction::HideToTray
            || !self.tray_ready
            || !ctx.input(|input| input.viewport().close_requested())
        {
            return;
        }
        ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }

    fn render(&mut self, ui: &mut egui::Ui) {
        egui::Panel::bottom("status-bar")
            .exact_size(28.0)
            .show(ui, |ui| {
                let status = if self.shortcut_recording.is_some() {
                    t!("recording_status").to_string()
                } else {
                    self.status.clone()
                };
                ui.horizontal_centered(|ui| ui.label(status));
            });

        egui::CentralPanel::default().show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("KOCR");
                ui.separator();
                ui.selectable_value(&mut self.page, Page::Capture, t!("tab_capture").as_ref());
                ui.selectable_value(&mut self.page, Page::Models, t!("tab_models").as_ref());
                ui.selectable_value(
                    &mut self.page,
                    Page::Shortcuts,
                    t!("tab_shortcuts").as_ref(),
                );
                ui.selectable_value(
                    &mut self.page,
                    Page::Preferences,
                    t!("tab_settings").as_ref(),
                );
            });
            ui.separator();

            match self.page {
                Page::Capture => self.render_capture(ui),
                Page::Models => self.render_models(ui),
                Page::Shortcuts => self.render_shortcuts(ui),
                Page::Preferences => self.render_preferences(ui),
            }
        });
    }

    fn render_capture(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if ui
                .add_enabled(
                    !self.capturing,
                    egui::Button::new(t!("capture_png").as_ref()),
                )
                .clicked()
            {
                self.capture(false, false);
            }
            if ui
                .add_enabled(
                    !self.capturing,
                    egui::Button::new(t!("capture_text").as_ref()),
                )
                .clicked()
            {
                self.capture(true, false);
            }
            if ui
                .add_enabled(
                    !self.capturing,
                    egui::Button::new(t!("capture_oneline").as_ref()),
                )
                .clicked()
            {
                self.capture(true, true);
            }
        });

        ui.add_space(10.0);
        let mut copy = None;
        let mut delete_id = None;
        let mut clear = false;
        const ROW_HEIGHT: f32 = 64.0;
        const CONTENT_HEIGHT: f32 = 56.0;
        let total_rows = self.history.len();

        ui.horizontal(|ui| {
            ui.label(t!("recent").as_ref());
            ui.label(
                egui::RichText::new(self.history.len().to_string())
                    .small()
                    .color(ui.visuals().weak_text_color()),
            );
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let clear_label = if self.confirm_clear {
                    t!("clear_history_confirm").into_owned()
                } else {
                    t!("clear_history").into_owned()
                };
                if ui
                    .add_enabled(!self.history.is_empty(), egui::Button::new(clear_label))
                    .clicked()
                {
                    if self.confirm_clear {
                        clear = true;
                        self.confirm_clear = false;
                    } else {
                        self.confirm_clear = true;
                    }
                }
            });
        });
        ui.add_space(4.0);

        let history = &self.history;
        let texture_cache = &mut self.texture_cache;

        if total_rows == 0 {
            ui.weak(t!("recent_empty").as_ref());
        } else {
            egui::ScrollArea::vertical()
                .max_height(ui.available_height())
                .auto_shrink([false, false])
                .show_rows(ui, ROW_HEIGHT, total_rows, |ui, rows| {
                    for row in rows {
                        let record = &history[row];
                        egui::Frame::group(ui.style())
                            .inner_margin(egui::Margin::symmetric(6, 2))
                            .show(ui, |ui| {
                                ui.set_width(ui.available_width());
                                ui.set_min_height(CONTENT_HEIGHT);
                                ui.allocate_ui_with_layout(
                                    egui::vec2(ui.available_width(), CONTENT_HEIGHT),
                                    egui::Layout::right_to_left(egui::Align::Center),
                                    |ui| {
                                        if ui
                                            .add(egui::Button::new(t!("delete").as_ref()))
                                            .clicked()
                                        {
                                            delete_id = Some(record.id);
                                        }
                                        if ui
                                            .add(egui::Button::new(t!("copy").as_ref()))
                                            .clicked()
                                        {
                                            copy = Some(match &record.content {
                                                RecordContent::Text(text) => {
                                                    CopyAction::Text(text.clone())
                                                }
                                                RecordContent::Image(path) => {
                                                    CopyAction::Image(path.clone())
                                                }
                                            });
                                        }

                                        ui.with_layout(
                                            egui::Layout::left_to_right(egui::Align::Center),
                                            |ui| {
                                                ui.label(
                                                    egui::RichText::new(&record.time)
                                                        .small()
                                                        .color(ui.visuals().weak_text_color()),
                                                );
                                                ui.add_space(6.0);
                                                let content_width =
                                                    ui.available_width().max(40.0);
                                                ui.allocate_ui_with_layout(
                                                    egui::vec2(
                                                        content_width,
                                                        CONTENT_HEIGHT,
                                                    ),
                                                    egui::Layout::left_to_right(
                                                        egui::Align::Center,
                                                    ),
                                                    |ui| {
                                                        ui.set_width(content_width);
                                                        match &record.content {
                                                            RecordContent::Text(text) => {
                                                                let full = text.clone();
                                                                let mut job =
                                                                    egui::text::LayoutJob::default();
                                                                job.wrap.max_width = content_width;
                                                                job.wrap.max_rows = 2;
                                                                job.wrap.break_anywhere = true;
                                                                job.append(
                                                                    text,
                                                                    0.0,
                                                                    egui::TextFormat {
                                                                        font_id:
                                                                            egui::TextStyle::Body
                                                                                .resolve(
                                                                                    ui.style(),
                                                                                ),
                                                                        color: ui
                                                                            .visuals()
                                                                            .text_color(),
                                                                        ..Default::default()
                                                                    },
                                                                );
                                                                ui.add(
                                                                    egui::Label::new(job)
                                                                        .show_tooltip_when_elided(
                                                                            false,
                                                                        ),
                                                                )
                                                                .on_hover_text_at_pointer(full);
                                                            }
                                                            RecordContent::Image(path) => {
                                                                if let std::collections::hash_map::Entry::Vacant(entry) =
                                                                    texture_cache.entry(record.id)
                                                                    && let Ok(texture) = texture_from_path(
                                                                        ui.ctx(),
                                                                        path,
                                                                        record.id,
                                                                    )
                                                                {
                                                                    entry.insert(texture);
                                                                }
                                                                if let Some(texture) =
                                                                    texture_cache.get(&record.id)
                                                                {
                                                                    let size = texture.size_vec2();
                                                                    let scale = (CONTENT_HEIGHT
                                                                        / size.y)
                                                                        .min(
                                                                            content_width
                                                                                / size.x,
                                                                        )
                                                                        .min(1.0);
                                                                    ui.add(
                                                                        egui::Image::new(texture)
                                                                            .fit_to_exact_size(
                                                                                size * scale,
                                                                            ),
                                                                    );
                                                                } else {
                                                                    ui.weak(t!("image_unavailable").as_ref());
                                                                }
                                                            }
                                                        }
                                                    },
                                                );
                                            },
                                        );
                                    },
                                );
                            });
                    }
                });
        }

        if clear {
            self.clear_history();
        } else if let Some(id) = delete_id {
            self.remove_record(id);
        }

        if let Some(action) = copy {
            let image = matches!(&action, CopyAction::Image(_));
            let result = match action {
                CopyAction::Text(text) => {
                    kocr_core::platform::copy_clipboard(text.as_bytes(), "text/plain;charset=utf-8")
                        .map_err(|error| error.to_string())
                }
                CopyAction::Image(path) => std::fs::read(path)
                    .map_err(|error| error.to_string())
                    .and_then(|png| {
                        kocr_core::platform::copy_clipboard(&png, "image/png")
                            .map_err(|error| error.to_string())
                    }),
            };
            self.status = match result {
                Ok(()) if image => t!("status_image_copied").to_string(),
                Ok(()) => t!("status_text_copied").to_string(),
                Err(error) => error.to_string(),
            };
        }
    }

    fn render_models(&mut self, ui: &mut egui::Ui) {
        let models = self.models.clone();
        let active = self.config.models.select.clone();
        let mut toggle = None;
        let mut action = None;

        egui::Grid::new("models")
            .num_columns(3)
            .spacing([12.0, 8.0])
            .striped(true)
            .show(ui, |ui| {
                for model in &models {
                    let mut checked = active.as_deref() == Some(model.name.as_str());
                    if ui
                        .add_enabled(model.installed, egui::Checkbox::without_text(&mut checked))
                        .changed()
                    {
                        toggle = Some((model.name.clone(), checked));
                    }

                    ui.label(&model.name);

                    if model.installed {
                        if ui
                            .add_enabled(
                                !self.installing,
                                egui::Button::new(t!("uninstall").as_ref()),
                            )
                            .clicked()
                        {
                            action = Some((false, model.name.clone()));
                        }
                    } else if ui
                        .add_enabled(!self.installing, egui::Button::new(t!("install").as_ref()))
                        .clicked()
                    {
                        action = Some((true, model.name.clone()));
                    }
                    ui.end_row();
                }
            });

        if let Some((name, checked)) = toggle {
            self.set_active_model(checked.then_some(name));
        }
        if let Some((install, name)) = action {
            if install {
                self.install(&name);
            } else {
                self.uninstall(&name);
            }
        }

        if let Some(progress) = &self.progress {
            ui.add_space(12.0);
            ui.add(
                egui::ProgressBar::new(progress_fraction(progress))
                    .text(progress_text(progress))
                    .desired_width(ui.available_width()),
            );
        }
    }

    fn save_preferences(&mut self) -> bool {
        match self.preferences.save() {
            Ok(()) => true,
            Err(error) => {
                self.status = error;
                false
            }
        }
    }

    fn render_preferences(&mut self, ui: &mut egui::Ui) {
        ui.label(egui::RichText::new(t!("language").as_ref()).strong());
        ui.add_space(2.0);
        let locale = rust_i18n::locale();
        if ui.radio(&*locale == "en", "English").clicked() {
            self.preferences.locale = "en".to_owned();
            rust_i18n::set_locale("en");
            if self.save_preferences() {
                self.status = t!("status_language", language = "English").to_string();
            }
        }
        if ui.radio(&*locale == "zh-CN", "简体中文").clicked() {
            self.preferences.locale = "zh-CN".to_owned();
            rust_i18n::set_locale("zh-CN");
            if self.save_preferences() {
                self.status = t!("status_language", language = "简体中文").to_string();
            }
        }

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(6.0);
        ui.label(egui::RichText::new(t!("appearance").as_ref()).strong());
        let mut theme = theme_preference(&self.preferences.theme);
        ui.horizontal(|ui| {
            ui.label(t!("theme").as_ref());
            ui.radio_value(
                &mut theme,
                egui::ThemePreference::System,
                t!("theme_system").as_ref(),
            );
            ui.radio_value(
                &mut theme,
                egui::ThemePreference::Light,
                t!("theme_light").as_ref(),
            );
            ui.radio_value(
                &mut theme,
                egui::ThemePreference::Dark,
                t!("theme_dark").as_ref(),
            );
        });
        if theme != theme_preference(&self.preferences.theme) {
            self.preferences.theme = theme_name(theme).to_owned();
            ui.ctx().set_theme(theme);
            if self.save_preferences() {
                self.status = t!("status_theme", theme = theme_label(theme)).to_string();
            }
        }

        ui.add_space(8.0);
        ui.horizontal(|ui| {
            ui.label(t!("font_size").as_ref());
            let response = ui.add(
                egui::Slider::new(&mut self.font_size_draft, 12.0..=22.0)
                    .step_by(1.0)
                    .integer(),
            );
            if response.drag_stopped() {
                self.preferences.font_size = self.font_size_draft;
                apply_ui_style(ui.ctx(), self.font_size_draft);
                if self.save_preferences() {
                    self.status = t!("status_font_size", size = self.font_size_draft).to_string();
                }
            }
        });

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(6.0);
        ui.label(egui::RichText::new(t!("history").as_ref()).strong());

        ui.add_space(8.0);
        let mut limit = self.history_limit_draft;
        ui.horizontal(|ui| {
            ui.label(t!("history_limit").as_ref());
            if ui
                .add(
                    egui::Slider::new(&mut limit, 10..=500)
                        .step_by(10.0)
                        .integer(),
                )
                .changed()
            {
                self.history_limit_draft = limit;
                self.confirm_history_apply = false;
            }
        });

        let current = self.history.len();
        let pending = current.saturating_sub(self.history_limit_draft);
        ui.label(t!("history_current", count = current).to_string());
        if pending > 0 {
            ui.colored_label(
                ui.visuals().warn_fg_color,
                t!("history_delete_pending", count = pending).to_string(),
            );
        }
        let apply_label = if pending > 0 && self.confirm_history_apply {
            t!("confirm_cleanup").to_string()
        } else {
            t!("apply").to_string()
        };
        if ui.button(apply_label).clicked() {
            if pending > 0 && !self.confirm_history_apply {
                self.confirm_history_apply = true;
            } else {
                let limit = self.history_limit_draft;
                self.apply_history_retention(limit);
                self.confirm_history_apply = false;
            }
        }

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(6.0);
        ui.label(egui::RichText::new(t!("behavior").as_ref()).strong());

        ui.add_space(8.0);
        ui.horizontal(|ui| {
            ui.label(t!("close_action").as_ref());
            let mut close_action = self.preferences.close_action;
            ui.radio_value(
                &mut close_action,
                CloseAction::Exit,
                t!("close_exit").as_ref(),
            );
            ui.radio_value(
                &mut close_action,
                CloseAction::HideToTray,
                t!("close_hide").as_ref(),
            );
            if self.preferences.close_action != close_action {
                self.preferences.close_action = close_action;
                if self.save_preferences() {
                    let action = match close_action {
                        CloseAction::Exit => t!("close_exit").to_string(),
                        CloseAction::HideToTray => t!("close_hide").to_string(),
                    };
                    self.status = t!("status_close_action", action = action).to_string();
                }
            }
        });

        ui.add_space(8.0);
        let remember = ui.checkbox(
            &mut self.preferences.remember_window_state,
            t!("remember_window_state").as_ref(),
        );
        if remember.changed() && self.save_preferences() {
            let state = if self.preferences.remember_window_state {
                t!("enabled").to_string()
            } else {
                t!("disabled").to_string()
            };
            self.status = t!("status_remember_window", state = state).to_string();
        }
    }

    fn render_shortcuts(&mut self, ui: &mut egui::Ui) {
        let mut button_rects = Vec::new();
        egui::Grid::new("shortcuts")
            .num_columns(2)
            .spacing([8.0, 8.0])
            .min_col_width(110.0)
            .show(ui, |ui| {
                for (field, label) in [
                    (ShortcutField::Copy, t!("copy")),
                    (ShortcutField::Ocr, t!("ocr")),
                    (ShortcutField::Oneline, t!("one_line")),
                ] {
                    ui.label(label.as_ref());
                    let recording = self.shortcut_recording == Some(field);
                    let value = if recording {
                        t!("press_shortcut").to_string()
                    } else {
                        format_shortcut(self.shortcut_value(field))
                    };
                    let response = ui.add(
                        egui::Button::new(value).min_size(egui::vec2(ui.available_width(), 0.0)),
                    );
                    button_rects.push(response.rect);
                    if response.clicked() {
                        self.shortcut_recording = Some(field);
                    }
                    ui.end_row();
                }
            });

        if self.shortcut_recording.is_some()
            && ui.ctx().input(|input| input.pointer.any_click())
            && ui
                .ctx()
                .input(|input| input.pointer.interact_pos())
                .is_some_and(|position| !button_rects.iter().any(|rect| rect.contains(position)))
        {
            self.shortcut_recording = None;
        }

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(8.0);

        ui.label(format!("{}: {}", t!("shortcuts"), self.shortcuts_status));
    }

    fn shortcut_value(&self, field: ShortcutField) -> &str {
        match field {
            ShortcutField::Copy => &self.copy,
            ShortcutField::Ocr => &self.ocr,
            ShortcutField::Oneline => &self.oneline,
        }
    }

    fn set_shortcut(&mut self, field: ShortcutField, value: String) {
        match field {
            ShortcutField::Copy => self.copy = value,
            ShortcutField::Ocr => self.ocr = value,
            ShortcutField::Oneline => self.oneline = value,
        }
    }

    fn capture_shortcut(&mut self, ctx: &egui::Context) {
        let Some(field) = self.shortcut_recording else {
            return;
        };
        let events = ctx.input(|input| input.events.clone());
        for event in events {
            let egui::Event::Key {
                key,
                pressed: true,
                repeat: false,
                modifiers,
                ..
            } = event
            else {
                continue;
            };

            if key == egui::Key::Escape {
                self.shortcut_recording = None;
                return;
            }
            if matches!(key, egui::Key::Backspace | egui::Key::Delete)
                && !modifiers.alt
                && !modifiers.ctrl
                && !modifiers.shift
                && !modifiers.mac_cmd
            {
                self.set_shortcut(field, String::new());
                self.save();
                self.shortcut_recording = None;
                return;
            }
            if let Some(shortcut) = shortcut_from_key(key, modifiers) {
                self.set_shortcut(field, shortcut);
                self.save();
                self.shortcut_recording = None;
                return;
            }
            self.status = t!("shortcut_modifier_required").to_string();
        }
    }
}

impl eframe::App for KocrApp {
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.capture_shortcut(ctx);
        self.poll();
        self.poll_tray(ctx);
        self.handle_close(ctx);
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.render(ui);
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.save();
    }
}

fn selected_model_status(config: &Config) -> String {
    match config.models.select.as_deref() {
        Some(name) => t!("selected_model", name = name).to_string(),
        None => t!("no_model_selected").to_string(),
    }
}

fn load_history(limit: usize) -> (Option<History>, Vec<CaptureRecord>, Option<String>) {
    let store = match History::open() {
        Ok(store) => store,
        Err(error) => return (None, Vec::new(), Some(error)),
    };
    match store.prune(limit) {
        Ok(paths) => history::remove_files(paths),
        Err(error) => return (Some(store), Vec::new(), Some(error)),
    }
    let records = match store.recent() {
        Ok(records) => records,
        Err(error) => return (Some(store), Vec::new(), Some(error)),
    };
    let mut history = Vec::with_capacity(records.len());
    for record in records {
        if let Some(record) = stored_record(record) {
            history.push(record);
        }
    }
    (Some(store), history, None)
}

fn stored_record(record: StoredRecord) -> Option<CaptureRecord> {
    let time = Local
        .timestamp_opt(record.created_at, 0)
        .single()
        .map(|time| time.format("%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| "--:--:--".to_owned());
    let content = match record.content {
        StoredContent::Text(text) => RecordContent::Text(text),
        StoredContent::Image(path) => RecordContent::Image(path),
    };
    Some(CaptureRecord {
        id: record.id,
        content,
        time,
    })
}

fn texture_from_path(
    ctx: &egui::Context,
    path: &std::path::Path,
    id: i64,
) -> Result<egui::TextureHandle, String> {
    let png = std::fs::read(path).map_err(|error| error.to_string())?;
    texture_from_png(ctx, &png, format!("capture-{id}"))
}

fn texture_from_png(
    ctx: &egui::Context,
    png: &[u8],
    name: String,
) -> Result<egui::TextureHandle, String> {
    let image = image::load_from_memory(png)
        .map_err(|error| error.to_string())?
        .to_rgba8();
    let (width, height) = image.dimensions();
    const DISPLAY_TEXTURE_MAX: u32 = 320;
    let scale = (DISPLAY_TEXTURE_MAX as f64 / width as f64)
        .min(DISPLAY_TEXTURE_MAX as f64 / height as f64)
        .min(1.0);
    let display = if scale < 1.0 {
        image::imageops::resize(
            &image,
            ((width as f64 * scale).round() as u32).max(1),
            ((height as f64 * scale).round() as u32).max(1),
            image::imageops::FilterType::Triangle,
        )
    } else {
        image
    };
    let (width, height) = display.dimensions();
    let color = egui::ColorImage::from_rgba_unmultiplied(
        [width as usize, height as usize],
        display.as_raw(),
    );
    Ok(ctx.load_texture(name, color, egui::TextureOptions::LINEAR))
}

fn load_models() -> Result<Vec<ModelRow>, String> {
    kocr_model::list()
        .map(|entries| {
            entries
                .into_iter()
                .map(|entry| ModelRow {
                    name: entry.name,
                    installed: entry.installed,
                })
                .collect()
        })
        .map_err(|error| error.to_string())
}

fn progress_fraction(progress: &Progress) -> f32 {
    match progress.total {
        Some(total) if total > 0 => (progress.downloaded as f32 / total as f32).clamp(0.0, 1.0),
        _ => 0.0,
    }
}

fn progress_text(progress: &Progress) -> String {
    match progress.total {
        Some(total) if total > 0 => {
            let percent = progress.downloaded.saturating_mul(100) / total;
            format!("Installing {percent}%")
        }
        _ => format!(
            "Installing {:.1} MiB",
            progress.downloaded as f64 / (1024.0 * 1024.0)
        ),
    }
}

fn shortcut_from_key(key: egui::Key, modifiers: egui::Modifiers) -> Option<String> {
    let key = config_key_name(key)?;
    let command = cfg!(target_os = "macos") && modifiers.mac_cmd;
    if !command && !modifiers.ctrl && !modifiers.alt {
        return None;
    }
    let mut parts = Vec::new();
    if command {
        parts.push("Super".to_owned());
    }
    if modifiers.ctrl {
        parts.push("Ctrl".to_owned());
    }
    if modifiers.alt {
        parts.push("Alt".to_owned());
    }
    if modifiers.shift {
        parts.push("Shift".to_owned());
    }
    parts.push(key);
    Some(parts.join("+"))
}

fn config_key_name(key: egui::Key) -> Option<String> {
    Some(
        match key {
            egui::Key::A => "A",
            egui::Key::B => "B",
            egui::Key::C => "C",
            egui::Key::D => "D",
            egui::Key::E => "E",
            egui::Key::F => "F",
            egui::Key::G => "G",
            egui::Key::H => "H",
            egui::Key::I => "I",
            egui::Key::J => "J",
            egui::Key::K => "K",
            egui::Key::L => "L",
            egui::Key::M => "M",
            egui::Key::N => "N",
            egui::Key::O => "O",
            egui::Key::P => "P",
            egui::Key::Q => "Q",
            egui::Key::R => "R",
            egui::Key::S => "S",
            egui::Key::T => "T",
            egui::Key::U => "U",
            egui::Key::V => "V",
            egui::Key::W => "W",
            egui::Key::X => "X",
            egui::Key::Y => "Y",
            egui::Key::Z => "Z",
            egui::Key::Num0 => "0",
            egui::Key::Num1 => "1",
            egui::Key::Num2 => "2",
            egui::Key::Num3 => "3",
            egui::Key::Num4 => "4",
            egui::Key::Num5 => "5",
            egui::Key::Num6 => "6",
            egui::Key::Num7 => "7",
            egui::Key::Num8 => "8",
            egui::Key::Num9 => "9",
            egui::Key::F1 => "F1",
            egui::Key::F2 => "F2",
            egui::Key::F3 => "F3",
            egui::Key::F4 => "F4",
            egui::Key::F5 => "F5",
            egui::Key::F6 => "F6",
            egui::Key::F7 => "F7",
            egui::Key::F8 => "F8",
            egui::Key::F9 => "F9",
            egui::Key::F10 => "F10",
            egui::Key::F11 => "F11",
            egui::Key::F12 => "F12",
            egui::Key::F13 => "F13",
            egui::Key::F14 => "F14",
            egui::Key::F15 => "F15",
            egui::Key::F16 => "F16",
            egui::Key::F17 => "F17",
            egui::Key::F18 => "F18",
            egui::Key::F19 => "F19",
            egui::Key::F20 => "F20",
            egui::Key::F21 => "F21",
            egui::Key::F22 => "F22",
            egui::Key::F23 => "F23",
            egui::Key::F24 => "F24",
            egui::Key::F25 => "F25",
            egui::Key::F26 => "F26",
            egui::Key::F27 => "F27",
            egui::Key::F28 => "F28",
            egui::Key::F29 => "F29",
            egui::Key::F30 => "F30",
            egui::Key::F31 => "F31",
            egui::Key::F32 => "F32",
            egui::Key::F33 => "F33",
            egui::Key::F34 => "F34",
            egui::Key::F35 => "F35",
            egui::Key::Escape => "Escape",
            egui::Key::Tab => "Tab",
            egui::Key::Backspace => "Backspace",
            egui::Key::Enter => "Return",
            egui::Key::Space => "Space",
            egui::Key::Insert => "Insert",
            egui::Key::Delete => "Delete",
            egui::Key::Home => "Home",
            egui::Key::End => "End",
            egui::Key::PageUp => "PageUp",
            egui::Key::PageDown => "PageDown",
            egui::Key::ArrowLeft => "Left",
            egui::Key::ArrowUp => "Up",
            egui::Key::ArrowRight => "Right",
            egui::Key::ArrowDown => "Down",
            egui::Key::Comma => "Comma",
            egui::Key::Backslash => "Backslash",
            egui::Key::Slash => "Slash",
            egui::Key::Minus => "Minus",
            egui::Key::Period => "Period",
            egui::Key::Semicolon => "Semicolon",
            egui::Key::Quote => "Apostrophe",
            egui::Key::Equals => "Equal",
            egui::Key::OpenBracket => "BracketLeft",
            egui::Key::CloseBracket => "BracketRight",
            egui::Key::Backtick => "Grave",
            _ => return None,
        }
        .to_owned(),
    )
}

fn format_shortcut(value: &str) -> String {
    let Ok(shortcut) = parse_shortcut(value.trim()) else {
        return if value.trim().is_empty() {
            t!("not_set").to_string()
        } else {
            value.to_owned()
        };
    };
    let mac = cfg!(target_os = "macos");
    let mut parts = Vec::new();
    if shortcut.modifiers.contains(ConfigModifiers::SUPER) {
        parts.push(if mac { "Cmd" } else { "Super" });
    }
    if shortcut.modifiers.contains(ConfigModifiers::CONTROL) {
        parts.push("Ctrl");
    }
    if shortcut.modifiers.contains(ConfigModifiers::ALT) {
        parts.push(if mac { "Opt" } else { "Alt" });
    }
    if shortcut.modifiers.contains(ConfigModifiers::SHIFT) {
        parts.push("Shift");
    }
    parts.push(display_key(shortcut.key));
    parts.join("+")
}

fn display_key(key: Key) -> &'static str {
    match key {
        Key::Character('0') => "0",
        Key::Character('1') => "1",
        Key::Character('2') => "2",
        Key::Character('3') => "3",
        Key::Character('4') => "4",
        Key::Character('5') => "5",
        Key::Character('6') => "6",
        Key::Character('7') => "7",
        Key::Character('8') => "8",
        Key::Character('9') => "9",
        Key::Character('A') => "A",
        Key::Character('B') => "B",
        Key::Character('C') => "C",
        Key::Character('D') => "D",
        Key::Character('E') => "E",
        Key::Character('F') => "F",
        Key::Character('G') => "G",
        Key::Character('H') => "H",
        Key::Character('I') => "I",
        Key::Character('J') => "J",
        Key::Character('K') => "K",
        Key::Character('L') => "L",
        Key::Character('M') => "M",
        Key::Character('N') => "N",
        Key::Character('O') => "O",
        Key::Character('P') => "P",
        Key::Character('Q') => "Q",
        Key::Character('R') => "R",
        Key::Character('S') => "S",
        Key::Character('T') => "T",
        Key::Character('U') => "U",
        Key::Character('V') => "V",
        Key::Character('W') => "W",
        Key::Character('X') => "X",
        Key::Character('Y') => "Y",
        Key::Character('Z') => "Z",
        Key::Function(1) => "F1",
        Key::Function(2) => "F2",
        Key::Function(3) => "F3",
        Key::Function(4) => "F4",
        Key::Function(5) => "F5",
        Key::Function(6) => "F6",
        Key::Function(7) => "F7",
        Key::Function(8) => "F8",
        Key::Function(9) => "F9",
        Key::Function(10) => "F10",
        Key::Function(11) => "F11",
        Key::Function(12) => "F12",
        Key::Function(13) => "F13",
        Key::Function(14) => "F14",
        Key::Function(15) => "F15",
        Key::Function(16) => "F16",
        Key::Function(17) => "F17",
        Key::Function(18) => "F18",
        Key::Function(19) => "F19",
        Key::Function(20) => "F20",
        Key::Function(21) => "F21",
        Key::Function(22) => "F22",
        Key::Function(23) => "F23",
        Key::Function(24) => "F24",
        Key::Function(25) => "F25",
        Key::Function(26) => "F26",
        Key::Function(27) => "F27",
        Key::Function(28) => "F28",
        Key::Function(29) => "F29",
        Key::Function(30) => "F30",
        Key::Function(31) => "F31",
        Key::Function(32) => "F32",
        Key::Function(33) => "F33",
        Key::Function(34) => "F34",
        Key::Function(35) => "F35",
        Key::Escape => "Esc",
        Key::Tab => "Tab",
        Key::Backspace => "Backspace",
        Key::Return => "Return",
        Key::Enter => "Enter",
        Key::Insert => "Insert",
        Key::Delete => "Delete",
        Key::Pause => "Pause",
        Key::Print => "Print",
        Key::Home => "Home",
        Key::End => "End",
        Key::Left => "Left",
        Key::Up => "Up",
        Key::Right => "Right",
        Key::Down => "Down",
        Key::PageUp => "PageUp",
        Key::PageDown => "PageDown",
        Key::Space => "Space",
        Key::Apostrophe => "Apostrophe",
        Key::Comma => "Comma",
        Key::Minus => "Minus",
        Key::Period => "Period",
        Key::Slash => "Slash",
        Key::Semicolon => "Semicolon",
        Key::Equal => "Equal",
        Key::BracketLeft => "BracketLeft",
        Key::Backslash => "Backslash",
        Key::BracketRight => "BracketRight",
        Key::Grave => "Grave",
        Key::AudioLowerVolume => "VolumeDown",
        Key::AudioMute => "Mute",
        Key::AudioRaiseVolume => "VolumeUp",
        Key::AudioPlay => "Play",
        Key::AudioStop => "Stop",
        Key::AudioPrev => "Prev",
        Key::AudioNext => "Next",
        Key::AudioPause => "PauseMedia",
        Key::BrightnessUp => "BrightnessUp",
        Key::BrightnessDown => "BrightnessDown",
        Key::Character(_) => "Key",
        Key::Function(_) => "F",
    }
}

fn validate_shortcuts(shortcuts: &[(&str, &str)]) -> Result<(), String> {
    let mut parsed = Vec::new();
    for &(field, shortcut) in shortcuts {
        let shortcut = shortcut.trim();
        if shortcut.is_empty() {
            continue;
        }
        let binding = parse_shortcut(shortcut).map_err(|error| format!("{field}: {error}"))?;
        if let Some((other, _)) = parsed.iter().find(|(_, existing)| *existing == binding) {
            return Err(format!("{field}: shortcut is already used by {other}"));
        }
        parsed.push((field, binding));
    }
    Ok(())
}

fn load_window_icon() -> egui::IconData {
    let image = image::load_from_memory(include_bytes!("../assets/icon.png"))
        .expect("embedded icon is valid")
        .into_rgba8();
    let (width, height) = image.dimensions();
    egui::IconData {
        rgba: image.into_raw(),
        width,
        height,
    }
}

fn setup_fonts(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.clear();
    fonts.families.clear();
    fonts.font_data.insert(
        "noto_sans".to_owned(),
        egui::FontData::from_static(include_bytes!("../assets/fonts/NotoSans.ttf")).into(),
    );
    fonts.font_data.insert(
        "kocr_cjk".to_owned(),
        egui::FontData::from_static(include_bytes!("../assets/fonts/kocr-cjk.otf")).into(),
    );
    fonts.families.insert(
        egui::FontFamily::Proportional,
        vec!["noto_sans".to_owned(), "kocr_cjk".to_owned()],
    );
    fonts.families.insert(
        egui::FontFamily::Monospace,
        vec!["noto_sans".to_owned(), "kocr_cjk".to_owned()],
    );
    ctx.set_fonts(fonts);
}

fn apply_ui_style(ctx: &egui::Context, size: f32) {
    ctx.all_styles_mut(|style| {
        style.spacing.button_padding = egui::vec2(6.0, 3.0);
        style.text_styles.insert(
            egui::TextStyle::Heading,
            egui::FontId::new(size + 3.0, egui::FontFamily::Proportional),
        );
        style.text_styles.insert(
            egui::TextStyle::Body,
            egui::FontId::new(size, egui::FontFamily::Proportional),
        );
        style.text_styles.insert(
            egui::TextStyle::Button,
            egui::FontId::new(size, egui::FontFamily::Proportional),
        );
        style.text_styles.insert(
            egui::TextStyle::Small,
            egui::FontId::new(size - 2.0, egui::FontFamily::Proportional),
        );
        style.text_styles.insert(
            egui::TextStyle::Monospace,
            egui::FontId::new(size, egui::FontFamily::Monospace),
        );
    });
}

fn theme_preference(value: &str) -> egui::ThemePreference {
    match value {
        "light" => egui::ThemePreference::Light,
        "dark" => egui::ThemePreference::Dark,
        _ => egui::ThemePreference::System,
    }
}

fn theme_label(theme: egui::ThemePreference) -> String {
    match theme {
        egui::ThemePreference::System => t!("theme_system").to_string(),
        egui::ThemePreference::Light => t!("theme_light").to_string(),
        egui::ThemePreference::Dark => t!("theme_dark").to_string(),
    }
}

fn theme_name(theme: egui::ThemePreference) -> &'static str {
    match theme {
        egui::ThemePreference::System => "system",
        egui::ThemePreference::Light => "light",
        egui::ThemePreference::Dark => "dark",
    }
}

#[cfg(target_os = "linux")]
fn configure_tray_window(options: &mut eframe::NativeOptions) {
    use winit::platform::x11::EventLoopBuilderExtX11;

    let has_x11 = std::env::var_os("DISPLAY").is_some_and(|display| !display.is_empty());
    if !has_x11 {
        return;
    }
    options.event_loop_builder = Some(Box::new(|builder| {
        builder.with_x11();
    }));
}

#[cfg(not(target_os = "linux"))]
fn configure_tray_window(_options: &mut eframe::NativeOptions) {}

fn main() -> eframe::Result {
    let preferences = Preferences::load();
    rust_i18n::set_locale(&preferences.locale);
    let persist_window = preferences.remember_window_state;
    let mut options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([560.0, 480.0])
            .with_min_inner_size([520.0, 440.0])
            .with_icon(load_window_icon()),
        renderer: eframe::Renderer::Glow,
        persist_window,
        ..Default::default()
    };
    configure_tray_window(&mut options);
    eframe::run_native(
        "KOCR",
        options,
        Box::new(move |cc| {
            setup_fonts(&cc.egui_ctx);
            apply_ui_style(&cc.egui_ctx, preferences.font_size);
            cc.egui_ctx.set_theme(theme_preference(&preferences.theme));
            Ok(Box::new(KocrApp::new(cc.egui_ctx.clone(), preferences)))
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::{progress_fraction, validate_shortcuts};
    use kocr_model::Progress;

    #[test]
    fn rejects_duplicate_shortcuts() {
        assert_eq!(
            validate_shortcuts(&[("copy", "Alt+1"), ("ocr", "Alt+1")]),
            Err("ocr: shortcut is already used by copy".to_owned())
        );
    }

    #[test]
    fn accepts_distinct_shortcuts() {
        assert_eq!(
            validate_shortcuts(&[("copy", "Alt+1"), ("ocr", "Alt+2"), ("one line", "")]),
            Ok(())
        );
    }

    #[test]
    fn maps_shortcut_keys() {
        use super::{config_key_name, shortcut_from_key};
        use eframe::egui;

        assert_eq!(config_key_name(egui::Key::Num1).as_deref(), Some("1"));
        let modifiers = egui::Modifiers {
            alt: true,
            ..Default::default()
        };
        assert_eq!(
            shortcut_from_key(egui::Key::Num1, modifiers).as_deref(),
            Some("Alt+1")
        );
    }

    #[test]
    fn formats_shortcuts_per_platform() {
        use super::format_shortcut;

        let expected = if cfg!(target_os = "macos") {
            "Opt+1"
        } else {
            "Alt+1"
        };
        assert_eq!(format_shortcut("Alt+1"), expected);
    }

    #[test]
    fn computes_download_fraction() {
        let progress = Progress {
            downloaded: 50,
            total: Some(200),
        };
        assert_eq!(progress_fraction(&progress), 0.25);
    }
}
