//! Settings window for models, shortcuts, and the shortcut daemon.

use std::thread;

use anyhow::{Error, Result};
use kocr_config::{Config, parse_shortcut};
use kocr_model::Progress;
use winio::prelude::*;

const DAEMON_UNIT: &str = "kocr.service";

struct Settings {
    window: Child<Window>,
    model_label: Child<Label>,
    model_combo: Child<ComboBox>,
    uninstall_button: Child<Button>,
    install_label: Child<Label>,
    install_combo: Child<ComboBox>,
    install_button: Child<Button>,
    copy_label: Child<Label>,
    copy_edit: Child<Edit>,
    ocr_label: Child<Label>,
    ocr_edit: Child<Edit>,
    oneline_label: Child<Label>,
    oneline_edit: Child<Edit>,
    save_button: Child<Button>,
    status_label: Child<Label>,
    daemon_label: Child<Label>,
    daemon_status_label: Child<Label>,
    daemon_start_button: Child<Button>,
    daemon_stop_button: Child<Button>,
    daemon_enable_button: Child<Button>,
    daemon_disable_button: Child<Button>,
    config: Config,
    models: Vec<String>,
    available: Vec<String>,
    load_error: Option<String>,
    installing: bool,
}

#[derive(Debug)]
enum Message {
    Close,
    Save,
    InstallModel,
    UninstallModel,
    InstallProgress(Progress),
    InstallFinished(Result<String, String>),
    StartDaemon,
    StopDaemon,
    EnableDaemon,
    DisableDaemon,
}

impl Component for Settings {
    type Error = Error;
    type Event = ();
    type Init<'a> = ();
    type Message = Message;

    async fn init(_init: Self::Init<'_>, _sender: &ComponentSender<Self>) -> Result<Self> {
        let (config, load_error) = match Config::load() {
            Ok(config) => (config, None),
            Err(error) => (Config::default(), Some(error.to_string())),
        };
        let models: Vec<String> = config
            .installed_model_names()
            .into_iter()
            .map(str::to_owned)
            .collect();
        let (available, list_error) = match available_models() {
            Ok(available) => (available, None),
            Err(error) => (Vec::new(), Some(error.to_string())),
        };
        let copy = config.shortcut.copy.clone().unwrap_or_default();
        let ocr = config.shortcut.ocr.clone().unwrap_or_default();
        let oneline = config.shortcut.oneline.clone().unwrap_or_default();
        let status = load_error.clone().or(list_error).unwrap_or_default();
        let daemon_status = daemon_status();

        init! {
            window: Window = (()) => {
                text: "kocr settings",
                size: Size::new(560.0, 560.0),
            },
            model_label: Label = (&window) => {
                text: "Model:",
                halign: HAlign::Right,
            },
            model_combo: ComboBox = (&window),
            uninstall_button: Button = (&window) => {
                text: "Uninstall",
            },
            install_label: Label = (&window) => {
                text: "Install:",
                halign: HAlign::Right,
            },
            install_combo: ComboBox = (&window),
            install_button: Button = (&window) => {
                text: "Install",
            },
            copy_label: Label = (&window) => {
                text: "Copy:",
                halign: HAlign::Right,
            },
            copy_edit: Edit = (&window) => {
                text: copy,
            },
            ocr_label: Label = (&window) => {
                text: "OCR:",
                halign: HAlign::Right,
            },
            ocr_edit: Edit = (&window) => {
                text: ocr,
            },
            oneline_label: Label = (&window) => {
                text: "One line:",
                halign: HAlign::Right,
            },
            oneline_edit: Edit = (&window) => {
                text: oneline,
            },
            save_button: Button = (&window) => {
                text: "Save",
            },
            status_label: Label = (&window) => {
                text: status,
            },
            daemon_label: Label = (&window) => {
                text: "Shortcuts:",
                halign: HAlign::Right,
            },
            daemon_status_label: Label = (&window) => {
                text: daemon_status,
            },
            daemon_start_button: Button = (&window) => {
                text: "Start",
            },
            daemon_stop_button: Button = (&window) => {
                text: "Stop",
            },
            daemon_enable_button: Button = (&window) => {
                text: "Enable at login",
            },
            daemon_disable_button: Button = (&window) => {
                text: "Disable at login",
            },
        }

        model_combo.set_items(&models)?;
        if let Some(index) = config
            .models
            .select
            .as_ref()
            .and_then(|name| models.iter().position(|model| model == name))
        {
            model_combo.set_selection(index)?;
        }
        install_combo.set_items(&available)?;

        window.show()?;
        Ok(Self {
            window,
            model_label,
            model_combo,
            uninstall_button,
            install_label,
            install_combo,
            install_button,
            copy_label,
            copy_edit,
            ocr_label,
            ocr_edit,
            oneline_label,
            oneline_edit,
            save_button,
            status_label,
            daemon_label,
            daemon_status_label,
            daemon_start_button,
            daemon_stop_button,
            daemon_enable_button,
            daemon_disable_button,
            config,
            models,
            available,
            load_error,
            installing: false,
        })
    }

    async fn start(&mut self, sender: &ComponentSender<Self>) -> ! {
        start! {
            sender,
            self.window => {
                WindowEvent::Close => Message::Close,
            },
            self.save_button => {
                ButtonEvent::Click => Message::Save,
            },
            self.install_button => {
                ButtonEvent::Click => Message::InstallModel,
            },
            self.uninstall_button => {
                ButtonEvent::Click => Message::UninstallModel,
            },
            self.daemon_start_button => {
                ButtonEvent::Click => Message::StartDaemon,
            },
            self.daemon_stop_button => {
                ButtonEvent::Click => Message::StopDaemon,
            },
            self.daemon_enable_button => {
                ButtonEvent::Click => Message::EnableDaemon,
            },
            self.daemon_disable_button => {
                ButtonEvent::Click => Message::DisableDaemon,
            },
        }
    }

    async fn update_children(&mut self) -> Result<bool> {
        update_children!(
            self.window,
            self.model_label,
            self.model_combo,
            self.uninstall_button,
            self.install_label,
            self.install_combo,
            self.install_button,
            self.copy_label,
            self.copy_edit,
            self.ocr_label,
            self.ocr_edit,
            self.oneline_label,
            self.oneline_edit,
            self.save_button,
            self.status_label,
            self.daemon_label,
            self.daemon_status_label,
            self.daemon_start_button,
            self.daemon_stop_button,
            self.daemon_enable_button,
            self.daemon_disable_button
        )
    }

    async fn update(
        &mut self,
        message: Self::Message,
        sender: &ComponentSender<Self>,
    ) -> Result<bool> {
        match message {
            Message::Close => {
                sender.output(());
                Ok(false)
            }
            Message::Save => {
                let status = match self.save() {
                    Ok(()) => "Saved".to_owned(),
                    Err(error) => error,
                };
                self.status_label.set_text(status)?;
                Ok(false)
            }
            Message::InstallModel => {
                if self.installing {
                    return Ok(false);
                }
                let Some(name) = self
                    .install_combo
                    .selection()?
                    .and_then(|index| self.available.get(index).cloned())
                else {
                    self.status_label.set_text("Select a model to install")?;
                    return Ok(false);
                };
                self.installing = true;
                self.status_label
                    .set_text(format!("Installing {name}..."))?;
                let sender = sender.clone();
                thread::spawn(move || {
                    let result = kocr_model::install(&name, None, |progress| {
                        sender.post(Message::InstallProgress(progress));
                    });
                    sender.post(Message::InstallFinished(
                        result
                            .map(|installed| installed.name)
                            .map_err(|error| error.to_string()),
                    ));
                });
                Ok(false)
            }
            Message::UninstallModel => {
                let Some(name) = self
                    .model_combo
                    .selection()?
                    .and_then(|index| self.models.get(index).cloned())
                else {
                    self.status_label
                        .set_text("Select an installed model to remove")?;
                    return Ok(false);
                };
                let status = match kocr_model::uninstall(&name) {
                    Ok(name) => match self.refresh_models() {
                        Ok(()) => format!("Uninstalled {name}"),
                        Err(error) => error.to_string(),
                    },
                    Err(error) => error.to_string(),
                };
                self.status_label.set_text(status)?;
                Ok(false)
            }
            Message::InstallProgress(progress) => {
                self.status_label.set_text(progress_text(&progress))?;
                Ok(false)
            }
            Message::InstallFinished(result) => {
                self.installing = false;
                let status = match result {
                    Ok(name) => match self.refresh_models() {
                        Ok(()) => format!("Installed {name}"),
                        Err(error) => error.to_string(),
                    },
                    Err(error) => error,
                };
                self.status_label.set_text(status)?;
                Ok(false)
            }
            Message::StartDaemon => {
                let result = prepare_daemon()
                    .and_then(|()| kocr_platform::service_start(DAEMON_UNIT).map_err(Into::into));
                self.daemon_action(result, "started")
            }
            Message::StopDaemon => {
                let result = kocr_platform::service_stop(DAEMON_UNIT).map_err(Into::into);
                self.daemon_action(result, "stopped")
            }
            Message::EnableDaemon => {
                let result = prepare_daemon()
                    .and_then(|()| kocr_platform::service_enable(DAEMON_UNIT).map_err(Into::into));
                self.daemon_action(result, "enabled")
            }
            Message::DisableDaemon => {
                let result = kocr_platform::service_disable(DAEMON_UNIT).map_err(Into::into);
                self.daemon_action(result, "disabled")
            }
        }
    }

    fn render(&mut self, _sender: &ComponentSender<Self>) -> Result<()> {
        let size = self.window.client_size()?;
        let mut grid = layout! {
            Grid::from_str(
                "auto,1*,auto",
                "auto,auto,auto,auto,auto,auto,auto,auto,auto,auto",
            )
            .unwrap(),
            self.model_label => { column: 0, row: 0, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.model_combo => { column: 1, row: 0, margin: Margin::new_all_same(6.0) },
            self.uninstall_button => { column: 2, row: 0, margin: Margin::new_all_same(6.0) },
            self.install_label => { column: 0, row: 1, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.install_combo => { column: 1, row: 1, margin: Margin::new_all_same(6.0) },
            self.install_button => { column: 2, row: 1, margin: Margin::new_all_same(6.0) },
            self.copy_label => { column: 0, row: 2, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.copy_edit => { column: 1, row: 2, column_span: 2, margin: Margin::new_all_same(6.0) },
            self.ocr_label => { column: 0, row: 3, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.ocr_edit => { column: 1, row: 3, column_span: 2, margin: Margin::new_all_same(6.0) },
            self.oneline_label => { column: 0, row: 4, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.oneline_edit => { column: 1, row: 4, column_span: 2, margin: Margin::new_all_same(6.0) },
            self.save_button => { column: 2, row: 5, halign: HAlign::Right, margin: Margin::new_all_same(6.0) },
            self.status_label => { column: 0, row: 6, column_span: 3, margin: Margin::new_all_same(6.0) },
            self.daemon_label => { column: 0, row: 7, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.daemon_status_label => { column: 1, row: 7, column_span: 2, margin: Margin::new_all_same(6.0) },
            self.daemon_start_button => { column: 0, row: 8, margin: Margin::new_all_same(6.0) },
            self.daemon_stop_button => { column: 1, row: 8, margin: Margin::new_all_same(6.0) },
            self.daemon_enable_button => { column: 0, row: 9, margin: Margin::new_all_same(6.0) },
            self.daemon_disable_button => { column: 1, row: 9, margin: Margin::new_all_same(6.0) },
        };
        grid.set_size(size)?;
        Ok(())
    }

    fn render_children(&mut self) -> Result<()> {
        Ok(())
    }
}

impl Settings {
    fn refresh_models(&mut self) -> Result<()> {
        self.config = Config::load()?;
        self.load_error = None;
        self.models = self
            .config
            .installed_model_names()
            .into_iter()
            .map(str::to_owned)
            .collect();
        self.model_combo.set_items(&self.models)?;
        if let Some(index) = self
            .config
            .models
            .select
            .as_ref()
            .and_then(|name| self.models.iter().position(|model| model == name))
        {
            self.model_combo.set_selection(index)?;
        }
        self.available = available_models()?;
        self.install_combo.set_items(&self.available)?;
        Ok(())
    }

    fn daemon_action(&mut self, result: Result<()>, action: &str) -> Result<bool> {
        let status = match result {
            Ok(()) => format!("Daemon {action}"),
            Err(error) => error.to_string(),
        };
        self.status_label.set_text(status)?;
        self.daemon_status_label.set_text(daemon_status())?;
        Ok(false)
    }

    fn save(&mut self) -> Result<(), String> {
        if let Some(error) = &self.load_error {
            return Err(error.clone());
        }

        let copy = self.copy_edit.text().map_err(|error| error.to_string())?;
        let ocr = self.ocr_edit.text().map_err(|error| error.to_string())?;
        let oneline = self
            .oneline_edit
            .text()
            .map_err(|error| error.to_string())?;
        for (field, shortcut) in [("copy", &copy), ("ocr", &ocr), ("one line", &oneline)] {
            let shortcut = shortcut.trim();
            if !shortcut.is_empty() {
                parse_shortcut(shortcut).map_err(|error| format!("{field}: {error}"))?;
            }
        }

        let mut config = self.config.clone();
        config.shortcut.copy = Some(copy.trim().to_owned());
        config.shortcut.ocr = Some(ocr.trim().to_owned());
        config.shortcut.oneline = Some(oneline.trim().to_owned());
        config.models.select = self
            .model_combo
            .selection()
            .map_err(|error| error.to_string())?
            .and_then(|index| self.models.get(index).cloned());
        config.save().map_err(|error| error.to_string())?;
        self.config = config;
        Ok(())
    }
}

fn available_models() -> Result<Vec<String>> {
    Ok(kocr_model::list()?
        .into_iter()
        .filter(|entry| !entry.installed)
        .map(|entry| entry.name)
        .collect())
}

fn prepare_daemon() -> Result<()> {
    let executable = std::env::current_exe()?;
    let directory = executable
        .parent()
        .ok_or_else(|| anyhow::anyhow!("invalid executable path"))?;
    kocr_platform::service_install(DAEMON_UNIT, &directory.join("kocr-daemon"))?;
    Ok(())
}

fn daemon_status() -> String {
    let state = kocr_platform::service_state(DAEMON_UNIT);
    let login = if kocr_platform::service_enabled(DAEMON_UNIT) {
        "enabled"
    } else {
        "disabled"
    };
    format!("{state}, login {login}")
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

fn main() -> Result<()> {
    App::builder()
        .name("io.github.KercyDing.kocr.settings")
        .build()?
        .block_on(Settings::run_until_event(()))
}
