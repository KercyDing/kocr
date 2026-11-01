use std::fs;
use std::path::PathBuf;

const FILE_NAME: &str = "preferences.conf";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CloseAction {
    #[default]
    Exit,
    HideToTray,
}

impl CloseAction {
    fn as_str(self) -> &'static str {
        match self {
            Self::Exit => "exit",
            Self::HideToTray => "hide_to_tray",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Preferences {
    pub theme: String,
    pub locale: String,
    pub close_action: CloseAction,
    pub remember_window_state: bool,
    pub launch_at_startup: bool,
    pub font_size: f32,
    pub history_limit: usize,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            theme: "system".to_owned(),
            locale: "en".to_owned(),
            close_action: CloseAction::Exit,
            remember_window_state: true,
            launch_at_startup: false,
            font_size: 15.0,
            history_limit: 50,
        }
    }
}

impl Preferences {
    pub fn load() -> Self {
        let Ok(path) = path() else {
            return Self::default();
        };
        let Ok(content) = fs::read_to_string(path) else {
            return Self::default();
        };
        parse(&content)
    }

    pub fn save(&self) -> Result<(), String> {
        let path = path()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        fs::write(path, self.render()).map_err(|error| error.to_string())
    }

    fn render(&self) -> String {
        format!(
            "theme={}\nlocale={}\nclose_action={}\nremember_window_state={}\nlaunch_at_startup={}\nfont_size={}\nhistory_limit={}\n",
            self.theme,
            self.locale,
            self.close_action.as_str(),
            self.remember_window_state,
            self.launch_at_startup,
            self.font_size,
            self.history_limit,
        )
    }
}

fn path() -> Result<PathBuf, String> {
    Ok(kocr_config::config_path().with_file_name(FILE_NAME))
}

fn parse(content: &str) -> Preferences {
    let mut preferences = Preferences::default();
    for line in content.lines() {
        if let Some(value) = line.strip_prefix("theme=") {
            let value = value.trim();
            if matches!(value, "system" | "light" | "dark") {
                preferences.theme = value.to_owned();
            }
        } else if let Some(value) = line.strip_prefix("locale=") {
            let value = value.trim();
            if matches!(value, "en" | "zh-CN") {
                preferences.locale = value.to_owned();
            }
        } else if let Some(value) = line.strip_prefix("close_action=") {
            preferences.close_action = match value.trim() {
                "hide_to_tray" => CloseAction::HideToTray,
                _ => CloseAction::Exit,
            };
        } else if let Some(value) = line.strip_prefix("remember_window_state=") {
            match value.trim() {
                "true" => preferences.remember_window_state = true,
                "false" => preferences.remember_window_state = false,
                _ => {}
            }
        } else if let Some(value) = line.strip_prefix("launch_at_startup=") {
            match value.trim() {
                "true" => preferences.launch_at_startup = true,
                "false" => preferences.launch_at_startup = false,
                _ => {}
            }
        } else if let Some(value) = line.strip_prefix("font_size=")
            && let Ok(size) = value.trim().parse::<f32>()
            && (12.0..=22.0).contains(&size)
        {
            preferences.font_size = size;
        } else if let Some(value) = line.strip_prefix("history_limit=")
            && let Ok(limit) = value.trim().parse::<usize>()
            && (10..=500).contains(&limit)
        {
            preferences.history_limit = limit;
        }
    }
    preferences
}

#[cfg(test)]
mod tests {
    use super::{CloseAction, Preferences, parse};

    #[test]
    fn parses_preferences() {
        let preferences = parse(
            "theme=dark\nlocale=zh-CN\nclose_action=hide_to_tray\nremember_window_state=false
launch_at_startup=true\n",
        );
        assert_eq!(preferences.theme, "dark");
        assert_eq!(preferences.locale, "zh-CN");
        assert_eq!(preferences.close_action, CloseAction::HideToTray);
        assert!(!preferences.remember_window_state);
        assert!(preferences.launch_at_startup);
        assert_eq!(preferences.font_size, 15.0);
        assert_eq!(preferences.history_limit, 50);
    }

    #[test]
    fn round_trips_through_render() {
        let preferences = Preferences {
            launch_at_startup: true,
            ..Preferences::default()
        };

        assert_eq!(parse(&preferences.render()), preferences);
    }

    #[test]
    fn ignores_invalid_values() {
        let preferences = parse("theme=blue\nlocale=fr\nremember_window_state=yes\n");
        assert_eq!(preferences, Preferences::default());
    }
}
