//! Application state, background work, and history persistence.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

use chrono::{Local, TimeZone};
use eframe::egui;
use kocr_config::Config;
use kocr_model::Progress;
use kocr_shortcuts::Action;

use crate::history::{Content as StoredContent, History, Record as StoredRecord};
use crate::models::{ModelRow, load_models};
use crate::preferences::{CloseAction, Preferences};
use crate::shortcuts::{shortcut_from_key, validate_shortcuts};
use crate::{history, tray};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Page {
    Capture,
    Models,
    Shortcuts,
    Preferences,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum ShortcutField {
    Copy,
    Save,
    Ocr,
    Oneline,
}

pub(crate) struct CaptureOutput {
    text: Option<String>,
    png: Vec<u8>,
}

pub(crate) enum RecordContent {
    Text(String),
    Image(PathBuf),
}

pub(crate) struct CaptureRecord {
    pub(crate) id: i64,
    pub(crate) content: RecordContent,
    pub(crate) time: String,
}

pub(crate) enum CopyAction {
    Text(String),
    Image(PathBuf),
}

pub(crate) enum Event {
    Models(Result<Vec<ModelRow>, String>),
    Shortcuts(String),
    Progress(Progress),
    Installed(Result<String, String>),
    Captured(Action, Result<CaptureOutput, String>),
    ShortcutCapture(Action),
}

pub(crate) struct KocrApp {
    pub(crate) ctx: egui::Context,
    pub(crate) tx: Sender<Event>,
    pub(crate) rx: Receiver<Event>,
    pub(crate) page: Page,
    pub(crate) config: Config,
    pub(crate) models: Vec<ModelRow>,
    pub(crate) load_error: Option<String>,
    pub(crate) preferences: Preferences,
    pub(crate) installing: bool,
    pub(crate) font_size_draft: f32,
    pub(crate) progress: Option<Progress>,
    pub(crate) capturing: bool,
    pub(crate) confirm_clear: bool,
    pub(crate) history_limit_draft: usize,
    pub(crate) confirm_history_apply: bool,
    pub(crate) history_store: Option<History>,
    pub(crate) history: Vec<CaptureRecord>,
    pub(crate) texture_cache: HashMap<i64, egui::TextureHandle>,
    pub(crate) preview: Option<(i64, egui::TextureHandle)>,
    pub(crate) status: String,
    pub(crate) copy: String,
    pub(crate) save: String,
    pub(crate) ocr: String,
    pub(crate) oneline: String,
    pub(crate) shortcut_recording: Option<ShortcutField>,
    pub(crate) tray: Option<tray::Tray>,
    pub(crate) tray_ready: bool,
    pub(crate) exit_requested: bool,
    pub(crate) shortcuts_status: String,
}

impl KocrApp {
    pub(crate) fn new(ctx: egui::Context, preferences: Preferences) -> Self {
        let (config, load_error) = match Config::load() {
            Ok(config) => (config, None),
            Err(error) => (Config::default(), Some(error.to_string())),
        };
        let models = Vec::new();
        let copy = config.shortcut.copy.clone().unwrap_or_default();
        let save = config.shortcut.save.clone().unwrap_or_default();
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
            let result = kocr_shortcuts::run(move |action| {
                let _ = capture_tx.send(Event::ShortcutCapture(action));
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
        if let Some(error) = tray_error.as_ref() {
            status = error.clone();
        }
        if preferences.launch_at_startup
            && let Err(error) = kocr_core::platform::set_autostart(true)
        {
            status = t!("status_launch_at_startup_failed", error = error).to_string();
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
            preview: None,
            status,
            copy,
            save,
            ocr,
            oneline,
            shortcut_recording: None,
            tray,
            tray_ready: false,
            exit_requested: false,
            shortcuts_status: t!("shortcuts_running").to_string(),
        }
    }

    pub(crate) fn poll(&mut self) {
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
                Event::ShortcutCapture(action) => {
                    self.capture(action);
                }
                Event::Captured(action, result) => {
                    self.capturing = false;
                    match result {
                        Ok(output) => {
                            let created_at = Local::now().timestamp();
                            let time = format_time(created_at);
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
                                    if action == Action::Save {
                                        self.save_png(&output.png);
                                    } else {
                                        self.status = t!("status_png_copied").to_string();
                                    }
                                }
                            }
                        }
                        Err(error) => self.status = error,
                    }
                }
            }
        }
    }

    pub(crate) fn store_text(&self, created_at: i64, text: &str) -> Result<i64, String> {
        self.history_store
            .as_ref()
            .map_or(Ok(-1), |store| store.insert_text(created_at, text))
    }

    pub(crate) fn store_image(
        &self,
        created_at: i64,
        png: &[u8],
    ) -> Result<(i64, PathBuf), String> {
        self.history_store
            .as_ref()
            .map_or(Ok((-1, PathBuf::new())), |store| {
                store.insert_image(created_at, png)
            })
    }

    pub(crate) fn trim_history(&mut self) {
        self.enforce_history_limit(self.preferences.history_limit);
    }

    pub(crate) fn enforce_history_limit(&mut self, limit: usize) -> bool {
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
        if !removed.is_empty() {
            self.preview = None;
        }
        for id in removed {
            self.texture_cache.remove(&id);
        }
        true
    }

    pub(crate) fn apply_history_retention(&mut self, limit: usize) {
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

    pub(crate) fn remove_record(&mut self, id: i64) {
        if let Some(store) = &self.history_store {
            match store.delete(id) {
                Ok(path) => {
                    if let Some(path) = path {
                        history::remove_files([path]);
                    }
                }
                Err(error) => {
                    self.status = error;
                    return;
                }
            }
        }
        self.texture_cache.remove(&id);
        if self
            .preview
            .as_ref()
            .is_some_and(|(preview_id, _)| *preview_id == id)
        {
            self.preview = None;
        }
        self.history.retain(|record| record.id != id);
        self.status = t!("status_record_deleted").to_string();
    }

    pub(crate) fn clear_history(&mut self) {
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
        self.preview = None;
        self.history.clear();
        self.status = t!("status_history_cleared").to_string();
    }

    pub(crate) fn refresh_models(&mut self) -> Result<(), String> {
        self.config = Config::load().map_err(|error| error.to_string())?;
        self.load_error = None;
        self.models = load_models()?;
        Ok(())
    }

    pub(crate) fn set_active_model(&mut self, name: Option<String>) {
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

    pub(crate) fn uninstall(&mut self, name: &str) {
        self.status = match kocr_model::uninstall(name) {
            Ok(name) => match self.refresh_models() {
                Ok(()) => t!("uninstalled", name = name).to_string(),
                Err(error) => error,
            },
            Err(error) => error.to_string(),
        };
    }

    pub(crate) fn install(&mut self, name: &str) {
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

    pub(crate) fn capture(&mut self, action: Action) {
        if self.capturing {
            return;
        }
        self.capturing = true;
        self.status = t!("status_capturing").to_string();

        let (recognize, oneline) = match action {
            Action::Copy | Action::Save => (false, false),
            Action::Ocr => (true, false),
            Action::Oneline => (true, true),
        };
        let tx = self.tx.clone();
        let ctx = self.ctx.clone();
        thread::spawn(move || {
            let result = kocr_core::capture::run(None, recognize, oneline)
                .map(|result| CaptureOutput {
                    text: result.text,
                    png: result.png,
                })
                .map_err(|error| match error {
                    kocr_core::AppError::Cancelled => t!("status_capture_cancelled").to_string(),
                    error => error.to_string(),
                });
            let _ = tx.send(Event::Captured(action, result));
            ctx.request_repaint();
        });
    }

    fn save_png(&mut self, png: &[u8]) {
        let file_name = format!("kocr-{}.png", Local::now().format("%Y%m%d-%H%M%S"));
        let Some(mut path) = rfd::FileDialog::new()
            .add_filter("PNG", &["png"])
            .set_file_name(file_name)
            .save_file()
        else {
            self.status = t!("status_save_cancelled").to_string();
            return;
        };
        if path.extension().is_none() {
            path.set_extension("png");
        }
        self.status = match std::fs::write(&path, png) {
            Ok(()) => t!("status_image_saved").to_string(),
            Err(error) => t!("status_save_failed", error = error).to_string(),
        };
    }

    pub(crate) fn save(&mut self) {
        if let Some(error) = &self.load_error {
            self.status = error.clone();
            return;
        }

        let copy = self.copy.trim();
        let save = self.save.trim();
        let ocr = self.ocr.trim();
        let oneline = self.oneline.trim();
        if let Err(error) = validate_shortcuts(&[
            ("copy", copy),
            ("save", save),
            ("ocr", ocr),
            ("one line", oneline),
        ]) {
            self.status = error;
            return;
        }

        let mut config = self.config.clone();
        config.shortcut.copy = Some(copy.to_owned());
        config.shortcut.save = Some(save.to_owned());
        config.shortcut.ocr = Some(ocr.to_owned());
        config.shortcut.oneline = Some(oneline.to_owned());
        if let Err(error) = config.save() {
            self.status = error.to_string();
        } else {
            self.config = config;
        }
    }

    pub(crate) fn poll_tray(&mut self, ctx: &egui::Context) {
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
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                }
            }
        }
        #[cfg(target_os = "linux")]
        if tray_failed {
            self.tray = None;
        }
    }

    pub(crate) fn handle_close(&self, ctx: &egui::Context) {
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

    pub(crate) fn shortcut_value(&self, field: ShortcutField) -> &str {
        match field {
            ShortcutField::Copy => &self.copy,
            ShortcutField::Save => &self.save,
            ShortcutField::Ocr => &self.ocr,
            ShortcutField::Oneline => &self.oneline,
        }
    }

    pub(crate) fn set_shortcut(&mut self, field: ShortcutField, value: String) {
        match field {
            ShortcutField::Copy => self.copy = value,
            ShortcutField::Save => self.save = value,
            ShortcutField::Ocr => self.ocr = value,
            ShortcutField::Oneline => self.oneline = value,
        }
    }

    pub(crate) fn capture_shortcut(&mut self, ctx: &egui::Context) {
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
    pub(crate) fn save_preferences(&mut self) -> bool {
        match self.preferences.save() {
            Ok(()) => true,
            Err(error) => {
                self.status = error;
                false
            }
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
    let time = format_time(record.created_at);
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

fn format_time(created_at: i64) -> String {
    Local
        .timestamp_opt(created_at, 0)
        .single()
        .map(|time| time.format("%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| "--:--:--".to_owned())
}

#[cfg(test)]
mod tests {
    use super::format_time;

    #[test]
    fn formats_record_time_with_date() {
        let formatted = format_time(0);

        assert_eq!(formatted.len(), "MM-DD HH:MM:SS".len());
        assert_eq!(&formatted[2..3], "-");
        assert_eq!(&formatted[5..6], " ");
        assert_eq!(&formatted[8..9], ":");
        assert_eq!(&formatted[11..12], ":");
    }
}
