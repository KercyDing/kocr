use eframe::egui;

pub(crate) fn apply_ui_style(ctx: &egui::Context, size: f32) {
    ctx.style_mut_of(egui::Theme::Light, |style| apply_style(style, size, false));
    ctx.style_mut_of(egui::Theme::Dark, |style| apply_style(style, size, true));
}

fn apply_style(style: &mut egui::Style, size: f32, dark: bool) {
    let (background, surface, elevated, text, muted, accent, accent_hover, border) = if dark {
        (
            egui::Color32::from_rgb(24, 25, 29),
            egui::Color32::from_rgb(31, 33, 39),
            egui::Color32::from_rgb(39, 42, 49),
            egui::Color32::from_rgb(235, 237, 242),
            egui::Color32::from_rgb(157, 163, 176),
            egui::Color32::from_rgb(112, 154, 235),
            egui::Color32::from_rgb(132, 170, 241),
            egui::Color32::from_rgb(63, 67, 78),
        )
    } else {
        (
            egui::Color32::from_rgb(247, 248, 250),
            egui::Color32::WHITE,
            egui::Color32::from_rgb(240, 242, 246),
            egui::Color32::from_rgb(31, 35, 43),
            egui::Color32::from_rgb(107, 114, 128),
            egui::Color32::from_rgb(54, 103, 196),
            egui::Color32::from_rgb(43, 87, 171),
            egui::Color32::from_rgb(218, 222, 230),
        )
    };

    style.spacing.item_spacing = egui::vec2(8.0, 8.0);
    style.spacing.window_margin = egui::Margin::same(16);
    style.spacing.button_padding = egui::vec2(11.0, 7.0);
    style.spacing.interact_size = egui::vec2(36.0, 32.0);
    style.spacing.icon_spacing = 7.0;
    style.visuals.dark_mode = dark;
    style.visuals.panel_fill = background;
    style.visuals.window_fill = surface;
    style.visuals.extreme_bg_color = background;
    style.visuals.faint_bg_color = elevated;
    style.visuals.text_edit_bg_color = Some(surface);
    style.visuals.weak_text_color = Some(muted);
    style.visuals.hyperlink_color = accent;
    style.visuals.warn_fg_color = egui::Color32::from_rgb(214, 155, 62);
    style.visuals.error_fg_color = egui::Color32::from_rgb(211, 92, 96);
    style.visuals.selection.bg_fill = if dark {
        egui::Color32::from_rgba_unmultiplied(112, 154, 235, 72)
    } else {
        egui::Color32::from_rgb(224, 233, 250)
    };
    style.visuals.selection.stroke = egui::Stroke::new(1.0, accent);
    style.visuals.window_corner_radius = egui::CornerRadius::same(10);

    let widgets = &mut style.visuals.widgets;
    widgets.noninteractive.bg_fill = surface;
    widgets.noninteractive.bg_stroke = egui::Stroke::new(1.0, border);
    widgets.noninteractive.fg_stroke.color = text;
    widgets.noninteractive.corner_radius = egui::CornerRadius::same(8);

    for widget in [&mut widgets.inactive, &mut widgets.open] {
        widget.bg_fill = surface;
        widget.weak_bg_fill = elevated;
        widget.bg_stroke = egui::Stroke::new(1.0, border);
        widget.fg_stroke.color = text;
        widget.corner_radius = egui::CornerRadius::same(8);
    }
    widgets.hovered = widgets.inactive;
    widgets.hovered.bg_fill = elevated;
    widgets.hovered.bg_stroke = egui::Stroke::new(1.0, accent_hover.gamma_multiply(0.65));
    widgets.active = widgets.hovered;
    widgets.active.bg_fill = if dark {
        accent.gamma_multiply(0.35)
    } else {
        egui::Color32::from_rgb(224, 233, 250)
    };
    widgets.active.bg_stroke = egui::Stroke::new(1.0, accent);

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
        egui::FontId::new((size - 2.0).max(10.0), egui::FontFamily::Proportional),
    );
    style.text_styles.insert(
        egui::TextStyle::Monospace,
        egui::FontId::new(size, egui::FontFamily::Monospace),
    );
}

pub(crate) fn theme_preference(value: &str) -> egui::ThemePreference {
    match value {
        "light" => egui::ThemePreference::Light,
        "dark" => egui::ThemePreference::Dark,
        _ => egui::ThemePreference::System,
    }
}
