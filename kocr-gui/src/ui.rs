//! Egui rendering.

use eframe::egui;
use kocr_shortcuts::Action;

use crate::app::{CopyAction, KocrApp, Page, RecordContent, ShortcutField};
use crate::models::{progress_fraction, progress_text};
use crate::preferences::CloseAction;
use crate::shortcuts::format_shortcut;
use crate::texture::{preview_from_path, texture_from_path};

impl KocrApp {
    pub(crate) fn render(&mut self, ui: &mut egui::Ui) {
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
                self.capture(Action::Copy);
            }
            if ui
                .add_enabled(
                    !self.capturing,
                    egui::Button::new(t!("capture_save").as_ref()),
                )
                .clicked()
            {
                self.capture(Action::Save);
            }
            if ui
                .add_enabled(
                    !self.capturing,
                    egui::Button::new(t!("capture_text").as_ref()),
                )
                .clicked()
            {
                self.capture(Action::Ocr);
            }
            if ui
                .add_enabled(
                    !self.capturing,
                    egui::Button::new(t!("capture_oneline").as_ref()),
                )
                .clicked()
            {
                self.capture(Action::Oneline);
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
        let preview = &mut self.preview;

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
                                                let content_width = ui.available_width().max(1.0);
                                                ui.allocate_ui_with_layout(
                                                    egui::vec2(content_width, CONTENT_HEIGHT),
                                                    egui::Layout::left_to_right(egui::Align::Center),
                                                    |ui| {
                                                        ui.set_width(content_width);
                                                        match &record.content {
                                                            RecordContent::Text(text) => {
                                                                let full = text.clone();
                                                                ui.add_sized(
                                                                    [content_width, CONTENT_HEIGHT],
                                                                    egui::Label::new(text)
                                                                        .truncate()
                                                                        .show_tooltip_when_elided(false),
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
                                                                    let response = ui.add(
                                                                        egui::Image::new(texture)
                                                                            .fit_to_exact_size(
                                                                                size * scale,
                                                                            ),
                                                                    );
                                                                    response.on_hover_ui(
                                                                        |ui| {
                                                                            if preview.as_ref().is_none_or(
                                                                                |(preview_id, _)| {
                                                                                    *preview_id
                                                                                        != record.id
                                                                                },
                                                                            ) && let Ok(texture) =
                                                                                preview_from_path(
                                                                                    ui.ctx(),
                                                                                    path,
                                                                                    record.id,
                                                                                )
                                                                            {
                                                                                *preview = Some((
                                                                                    record.id,
                                                                                    texture,
                                                                                ));
                                                                            }
                                                                            let texture = preview
                                                                                .as_ref()
                                                                                .filter(
                                                                                    |(preview_id, _)| {
                                                                                        *preview_id
                                                                                            == record.id
                                                                                    },
                                                                                )
                                                                                .map_or(
                                                                                    texture,
                                                                                    |(_, texture)| {
                                                                                        texture
                                                                                    },
                                                                                );
                                                                            const PREVIEW_WIDTH: f32 =
                                                                                320.0;
                                                                            const PREVIEW_HEIGHT: f32 =
                                                                                200.0;
                                                                            let size = texture
                                                                                .size_vec2();
                                                                            let scale = (PREVIEW_WIDTH
                                                                                / size.x)
                                                                                .min(
                                                                                    PREVIEW_HEIGHT
                                                                                        / size.y,
                                                                                )
                                                                                .min(1.0);
                                                                            ui.allocate_ui(
                                                                                egui::vec2(
                                                                                    PREVIEW_WIDTH,
                                                                                    PREVIEW_HEIGHT,
                                                                                ),
                                                                                |ui| {
                                                                                    ui.set_min_size(
                                                                                        egui::vec2(
                                                                                            PREVIEW_WIDTH,
                                                                                            PREVIEW_HEIGHT,
                                                                                        ),
                                                                                    );
                                                                                    ui.vertical_centered(
                                                                                        |ui| {
                                                                                            ui.add_space(
                                                                                                ((PREVIEW_HEIGHT
                                                                                                    - size.y
                                                                                                        * scale)
                                                                                                    / 2.0)
                                                                                                    .max(
                                                                                                        0.0,
                                                                                                    ),
                                                                                            );
                                                                                            ui.add(
                                                                                                egui::Image::new(
                                                                                                    texture,
                                                                                                )
                                                                                                .fit_to_exact_size(
                                                                                                    size * scale,
                                                                                                ),
                                                                                            );
                                                                                        },
                                                                                    );
                                                                                },
                                                                            );
                                                                        },
                                                                    );
                                                                } else {
                                                                    ui.weak(t!("preview_unavailable").as_ref());
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
                    (ShortcutField::Save, t!("save")),
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
}

pub(crate) fn setup_fonts(ctx: &egui::Context) {
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

pub(crate) fn apply_ui_style(ctx: &egui::Context, size: f32) {
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

pub(crate) fn theme_preference(value: &str) -> egui::ThemePreference {
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
