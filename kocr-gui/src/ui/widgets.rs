use eframe::egui;

#[derive(Clone, Copy)]
pub(crate) enum ButtonKind {
    Primary,
    Secondary,
    Ghost,
    Danger,
}

pub(crate) fn tab(ui: &mut egui::Ui, selected: bool, text: impl Into<String>) -> egui::Response {
    let (rect, response) = ui.allocate_exact_size(egui::vec2(88.0, 32.0), egui::Sense::click());
    let visuals = ui.visuals();
    let fill = if selected {
        visuals.selection.bg_fill
    } else if response.hovered() {
        visuals.widgets.hovered.bg_fill
    } else {
        egui::Color32::TRANSPARENT
    };
    if fill != egui::Color32::TRANSPARENT {
        ui.painter()
            .rect_filled(rect, egui::CornerRadius::same(7), fill);
    }
    let text_color = if selected {
        visuals.selection.stroke.color
    } else {
        visuals.widgets.noninteractive.fg_stroke.color
    };
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        text.into(),
        egui::TextStyle::Button.resolve(ui.style()),
        text_color,
    );
    response
}

pub(crate) fn slider(
    ui: &mut egui::Ui,
    add_slider: impl FnOnce(&mut egui::Ui) -> egui::Response,
) -> egui::Response {
    ui.scope(|ui| {
        let rail = ui.visuals().faint_bg_color;
        let accent = ui.visuals().hyperlink_color;
        let visuals = ui.visuals_mut();
        for widget in [
            &mut visuals.widgets.inactive,
            &mut visuals.widgets.hovered,
            &mut visuals.widgets.active,
        ] {
            widget.bg_fill = rail;
            widget.fg_stroke.color = accent;
        }
        add_slider(ui)
    })
    .inner
}

pub(crate) fn button(
    ui: &mut egui::Ui,
    text: impl Into<egui::WidgetText>,
    enabled: bool,
    kind: ButtonKind,
) -> egui::Response {
    button_sized(ui, text, enabled, kind, None)
}

pub(crate) fn button_sized(
    ui: &mut egui::Ui,
    text: impl Into<egui::WidgetText>,
    enabled: bool,
    kind: ButtonKind,
    min_size: Option<egui::Vec2>,
) -> egui::Response {
    ui.scope(|ui| {
        let visuals = ui.visuals_mut();
        let accent = visuals.hyperlink_color;
        let danger = visuals.error_fg_color;
        let base = match kind {
            ButtonKind::Primary => accent,
            ButtonKind::Danger => danger.gamma_multiply(0.16),
            ButtonKind::Secondary => visuals.widgets.inactive.weak_bg_fill,
            ButtonKind::Ghost => egui::Color32::TRANSPARENT,
        };
        let hover = match kind {
            ButtonKind::Primary => accent.gamma_multiply(0.86),
            ButtonKind::Danger => danger.gamma_multiply(0.26),
            ButtonKind::Secondary => visuals.widgets.hovered.bg_fill,
            ButtonKind::Ghost => visuals.widgets.hovered.bg_fill,
        };
        let foreground = if matches!(kind, ButtonKind::Primary) {
            egui::Color32::WHITE
        } else if matches!(kind, ButtonKind::Danger) {
            danger
        } else {
            visuals.widgets.inactive.fg_stroke.color
        };

        for widget in [
            &mut visuals.widgets.inactive,
            &mut visuals.widgets.open,
            &mut visuals.widgets.hovered,
            &mut visuals.widgets.active,
        ] {
            widget.fg_stroke.color = foreground;
            widget.corner_radius = egui::CornerRadius::same(8);
        }
        visuals.widgets.inactive.bg_fill = base;
        visuals.widgets.open.bg_fill = base;
        visuals.widgets.hovered.bg_fill = hover;
        visuals.widgets.active.bg_fill = hover;
        if matches!(kind, ButtonKind::Ghost) {
            visuals.widgets.inactive.bg_stroke = egui::Stroke::NONE;
        }

        let label = egui::RichText::new(text.into().text().to_string()).color(foreground);
        let mut button = egui::Button::new(label)
            .fill(base)
            .corner_radius(egui::CornerRadius::same(8));
        if let Some(min_size) = min_size {
            button = button.min_size(min_size);
        }
        ui.add_enabled(enabled, button)
    })
    .inner
}

pub(crate) fn card(ui: &mut egui::Ui, add_contents: impl FnOnce(&mut egui::Ui)) {
    let visuals = ui.visuals();
    egui::Frame::new()
        .fill(visuals.window_fill)
        .stroke(egui::Stroke::new(
            1.0,
            visuals.widgets.noninteractive.bg_stroke.color,
        ))
        .corner_radius(egui::CornerRadius::same(10))
        .inner_margin(egui::Margin::same(12))
        .show(ui, add_contents);
}

pub(crate) fn section_title(ui: &mut egui::Ui, title: impl Into<String>) {
    ui.label(egui::RichText::new(title).strong());
    ui.add_space(2.0);
}
