//! Settings window: edits the shared configuration file and exits.

use anyhow::{Error, Result};
use kocr_config::{Config, parse_shortcut};
use winio::prelude::*;

struct Settings {
    window: Child<Window>,
    model_label: Child<Label>,
    model_combo: Child<ComboBox>,
    copy_label: Child<Label>,
    copy_edit: Child<Edit>,
    ocr_label: Child<Label>,
    ocr_edit: Child<Edit>,
    oneline_label: Child<Label>,
    oneline_edit: Child<Edit>,
    save_button: Child<Button>,
    status_label: Child<Label>,
    config: Config,
    models: Vec<String>,
    load_error: Option<String>,
}

enum Message {
    Close,
    Save,
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
        let mut models: Vec<String> = config.models.installed.keys().cloned().collect();
        models.sort();
        let copy = config.shortcut.copy.clone().unwrap_or_default();
        let ocr = config.shortcut.ocr.clone().unwrap_or_default();
        let oneline = config.shortcut.oneline.clone().unwrap_or_default();
        let status = load_error.clone().unwrap_or_default();

        init! {
            window: Window = (()) => {
                text: "kocr settings",
                size: Size::new(480.0, 300.0),
            },
            model_label: Label = (&window) => {
                text: "Model:",
                halign: HAlign::Right,
            },
            model_combo: ComboBox = (&window),
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

        window.show()?;
        Ok(Self {
            window,
            model_label,
            model_combo,
            copy_label,
            copy_edit,
            ocr_label,
            ocr_edit,
            oneline_label,
            oneline_edit,
            save_button,
            status_label,
            config,
            models,
            load_error,
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
        }
    }

    async fn update_children(&mut self) -> Result<bool> {
        update_children!(
            self.window,
            self.model_label,
            self.model_combo,
            self.copy_label,
            self.copy_edit,
            self.ocr_label,
            self.ocr_edit,
            self.oneline_label,
            self.oneline_edit,
            self.save_button,
            self.status_label
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
        }
    }

    fn render(&mut self, _sender: &ComponentSender<Self>) -> Result<()> {
        let size = self.window.client_size()?;
        let mut grid = layout! {
            Grid::from_str("auto,1*", "auto,auto,auto,auto,auto,auto").unwrap(),
            self.model_label => { column: 0, row: 0, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.model_combo => { column: 1, row: 0, margin: Margin::new_all_same(6.0) },
            self.copy_label => { column: 0, row: 1, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.copy_edit => { column: 1, row: 1, margin: Margin::new_all_same(6.0) },
            self.ocr_label => { column: 0, row: 2, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.ocr_edit => { column: 1, row: 2, margin: Margin::new_all_same(6.0) },
            self.oneline_label => { column: 0, row: 3, valign: VAlign::Center, margin: Margin::new_all_same(6.0) },
            self.oneline_edit => { column: 1, row: 3, margin: Margin::new_all_same(6.0) },
            self.save_button => { column: 1, row: 4, halign: HAlign::Right, margin: Margin::new_all_same(6.0) },
            self.status_label => { column: 0, row: 5, column_span: 2, margin: Margin::new_all_same(6.0) },
        };
        grid.set_size(size)?;
        Ok(())
    }

    fn render_children(&mut self) -> Result<()> {
        Ok(())
    }
}

impl Settings {
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

fn main() -> Result<()> {
    App::builder()
        .name("io.github.KercyDing.kocr.settings")
        .build()?
        .block_on(Settings::run_until_event(()))
}
