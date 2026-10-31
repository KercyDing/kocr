#![cfg_attr(windows, windows_subsystem = "windows")]
//! Desktop app for capture, OCR models, shortcuts, and the system tray.

mod history;
mod i18n;
mod preferences;
mod tray;

use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

use chrono::{Local, TimeZone};
use eframe::egui;
use history::{Content as StoredContent, History, Record as StoredRecord};
use kocr_config::{Config, parse_shortcut};
use kocr_model::Progress;
use preferences::{CloseAction, Preferences};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Page {
    Capture,
    Models,
    Shortcuts,
    Preferences,
}

struct CaptureOutput {
    text: Option<String>,
    png: Vec<u8>,
}

enum RecordContent {
    Text(String),
    Image {
        texture: egui::TextureHandle,
        png: Arc<Vec<u8>>,
    },
}

struct CaptureRecord {
    id: i64,
    content: RecordContent,
    time: String,
}

enum CopyAction {
    Text(String),
    Image(Arc<Vec<u8>>),
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
    history_store: Option<History>,
    history: Vec<CaptureRecord>,
    status: String,
    copy: String,
    ocr: String,
    oneline: String,
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
            let result = kocr_shortcuts::run(|recognize, oneline| {
                kocr_core::capture::run(None, recognize, oneline).map(|_| ())
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
        let (history_store, history, history_error) = load_history(&ctx);
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
            history_store,
            history,
            status,
            copy,
            ocr,
            oneline,
            tray,
            tray_ready: false,
            exit_requested: false,
            shortcuts_status: t!("shortcuts_running").to_string(),
        }
    }

    fn poll(&mut self, ctx: &egui::Context) {
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
                                None => match texture_from_png(
                                    ctx,
                                    &output.png,
                                    format!("capture-{created_at}"),
                                ) {
                                    Ok(texture) => {
                                        let png = Arc::new(output.png);
                                        let id = self.store_image(created_at, &png).unwrap_or_else(
                                            |error| {
                                                self.status = error;
                                                -1
                                            },
                                        );
                                        self.history.insert(
                                            0,
                                            CaptureRecord {
                                                id,
                                                content: RecordContent::Image { texture, png },
                                                time,
                                            },
                                        );
                                        self.trim_history();
                                        self.status = t!("status_png_copied").to_string();
                                    }
                                    Err(error) => self.status = error,
                                },
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

    fn store_image(&self, created_at: i64, png: &[u8]) -> Result<i64, String> {
        self.history_store
            .as_ref()
            .map_or(Ok(-1), |store| store.insert_image(created_at, png))
    }

    fn trim_history(&mut self) {
        while self.history.len() > 50 {
            self.history.pop();
        }
    }

    fn remove_record(&mut self, id: i64) {
        if id >= 0
            && let Some(store) = &self.history_store
            && let Err(error) = store.delete(id)
        {
            self.status = error;
        }
        self.history.retain(|record| record.id != id);
    }

    fn clear_history(&mut self) {
        if let Some(store) = &self.history_store
            && let Err(error) = store.clear()
        {
            self.status = error;
            return;
        }
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
            .exact_size(24.0)
            .show(ui, |ui| {
                ui.horizontal_centered(|ui| ui.label(&self.status));
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
        const LIST_HEIGHT: f32 = 220.0;
        const ROW_HEIGHT: f32 = 32.0;
        const CONTENT_HEIGHT: f32 = 24.0;
        let total_rows = self.history.len();

        ui.horizontal(|ui| {
            ui.label(t!("recent").as_ref());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui
                    .add_enabled(
                        !self.history.is_empty(),
                        egui::Button::new(t!("clear_history").as_ref()),
                    )
                    .clicked()
                {
                    clear = true;
                }
            });
        });
        ui.add_space(4.0);

        if total_rows == 0 {
            ui.weak(t!("recent_empty").as_ref());
        } else {
            egui::ScrollArea::vertical()
                .max_height(LIST_HEIGHT)
                .auto_shrink([false, true])
                .show_rows(ui, ROW_HEIGHT, total_rows, |ui, rows| {
                    for row in rows {
                        let record = &self.history[row];
                        egui::Frame::group(ui.style())
                            .inner_margin(egui::Margin::symmetric(6, 2))
                            .show(ui, |ui| {
                                ui.set_width(ui.available_width());
                                ui.set_min_height(CONTENT_HEIGHT);
                                ui.horizontal_centered(|ui| {
                                    ui.label(
                                        egui::RichText::new(&record.time)
                                            .small()
                                            .color(ui.visuals().weak_text_color()),
                                    );
                                    ui.add_space(6.0);

                                    let content_width = (ui.available_width() - 96.0).max(40.0);
                                    ui.allocate_ui_with_layout(
                                        egui::vec2(content_width, ROW_HEIGHT),
                                        egui::Layout::left_to_right(egui::Align::Center),
                                        |ui| {
                                            ui.set_width(content_width);
                                            match &record.content {
                                                RecordContent::Text(text) => {
                                                    let text = text.replace('\n', " ");
                                                    ui.add(egui::Label::new(text).truncate());
                                                }
                                                RecordContent::Image { texture, .. } => {
                                                    let size = texture.size_vec2();
                                                    let scale = (CONTENT_HEIGHT / size.y)
                                                        .min(content_width / size.x)
                                                        .min(1.0);
                                                    ui.add(
                                                        egui::Image::new(texture)
                                                            .fit_to_exact_size(size * scale),
                                                    );
                                                }
                                            }
                                        },
                                    );

                                    if ui.small_button(t!("copy").as_ref()).clicked() {
                                        copy = Some(match &record.content {
                                            RecordContent::Text(text) => {
                                                CopyAction::Text(text.clone())
                                            }
                                            RecordContent::Image { png, .. } => {
                                                CopyAction::Image(png.clone())
                                            }
                                        });
                                    }
                                    if ui.small_button(t!("delete").as_ref()).clicked() {
                                        delete_id = Some(record.id);
                                    }
                                });
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
            let result = match action {
                CopyAction::Text(text) => {
                    kocr_core::platform::copy_clipboard(text.as_bytes(), "text/plain;charset=utf-8")
                }
                CopyAction::Image(png) => kocr_core::platform::copy_clipboard(&png, "image/png"),
            };
            self.status = match result {
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

    fn save_preferences(&mut self) {
        if let Err(error) = self.preferences.save() {
            self.status = error;
        }
    }

    fn render_preferences(&mut self, ui: &mut egui::Ui) {
        ui.label(egui::RichText::new(t!("language").as_ref()).strong());
        ui.add_space(2.0);
        let locale = i18n::locale();
        if ui.radio(&*locale == "zh-CN", "简体中文").clicked() {
            self.preferences.locale = "zh-CN".to_owned();
            i18n::set_locale("zh-CN");
            self.save_preferences();
        }
        if ui.radio(&*locale == "en", "English").clicked() {
            self.preferences.locale = "en".to_owned();
            i18n::set_locale("en");
            self.save_preferences();
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
            self.save_preferences();
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
                self.save_preferences();
            }
        });

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
                self.save_preferences();
            }
        });

        ui.add_space(8.0);
        if ui
            .checkbox(
                &mut self.preferences.remember_window_state,
                t!("remember_window_state").as_ref(),
            )
            .changed()
        {
            self.save_preferences();
        }
    }

    fn render_shortcuts(&mut self, ui: &mut egui::Ui) {
        egui::Grid::new("shortcuts")
            .num_columns(2)
            .spacing([8.0, 8.0])
            .min_col_width(110.0)
            .show(ui, |ui| {
                ui.label(t!("copy").as_ref());
                if ui
                    .add(egui::TextEdit::singleline(&mut self.copy).desired_width(f32::INFINITY))
                    .lost_focus()
                {
                    self.save();
                }
                ui.end_row();

                ui.label(t!("ocr").as_ref());
                if ui
                    .add(egui::TextEdit::singleline(&mut self.ocr).desired_width(f32::INFINITY))
                    .lost_focus()
                {
                    self.save();
                }
                ui.end_row();

                ui.label(t!("one_line").as_ref());
                if ui
                    .add(egui::TextEdit::singleline(&mut self.oneline).desired_width(f32::INFINITY))
                    .lost_focus()
                {
                    self.save();
                }
                ui.end_row();
            });

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(8.0);

        ui.label(format!("{}: {}", t!("shortcuts"), self.shortcuts_status));
    }
}

impl eframe::App for KocrApp {
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll(ctx);
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

fn load_history(ctx: &egui::Context) -> (Option<History>, Vec<CaptureRecord>, Option<String>) {
    let store = match History::open() {
        Ok(store) => store,
        Err(error) => return (None, Vec::new(), Some(error)),
    };
    let records = match store.recent() {
        Ok(records) => records,
        Err(error) => return (Some(store), Vec::new(), Some(error)),
    };
    let mut history = Vec::with_capacity(records.len());
    for record in records {
        if let Some(record) = stored_record(ctx, record) {
            history.push(record);
        }
    }
    (Some(store), history, None)
}

fn stored_record(ctx: &egui::Context, record: StoredRecord) -> Option<CaptureRecord> {
    let time = Local
        .timestamp_opt(record.created_at, 0)
        .single()
        .map(|time| time.format("%H:%M:%S").to_string())
        .unwrap_or_else(|| "--:--:--".to_owned());
    let content = match record.content {
        StoredContent::Text(text) => RecordContent::Text(text),
        StoredContent::Image(png) => {
            let png = Arc::new(png);
            let texture =
                texture_from_png(ctx, &png, format!("capture-{}", record.created_at)).ok()?;
            RecordContent::Image { texture, png }
        }
    };
    Some(CaptureRecord {
        id: record.id,
        content,
        time,
    })
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
    fonts.font_data.insert(
        "kocr_cjk".to_owned(),
        egui::FontData::from_static(include_bytes!("../assets/fonts/kocr-cjk.otf")).into(),
    );
    for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
        fonts
            .families
            .entry(family)
            .or_default()
            .push("kocr_cjk".to_owned());
    }
    ctx.set_fonts(fonts);
}

fn apply_ui_style(ctx: &egui::Context, size: f32) {
    ctx.all_styles_mut(|style| {
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
    i18n::set_locale(&preferences.locale);
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
    fn computes_download_fraction() {
        let progress = Progress {
            downloaded: 50,
            total: Some(200),
        };
        assert_eq!(progress_fraction(&progress), 0.25);
    }
}
