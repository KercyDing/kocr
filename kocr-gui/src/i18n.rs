use std::borrow::Cow;
use std::sync::atomic::{AtomicU8, Ordering};

static LOCALE: AtomicU8 = AtomicU8::new(0);

pub fn set_locale(locale: &str) {
    LOCALE.store(u8::from(locale == "zh-CN"), Ordering::Relaxed);
}

pub fn locale() -> String {
    if LOCALE.load(Ordering::Relaxed) == 0 {
        "en".to_owned()
    } else {
        "zh-CN".to_owned()
    }
}

pub fn translate(key: &'static str) -> Cow<'static, str> {
    let english = english(key);
    if LOCALE.load(Ordering::Relaxed) == 0 {
        return Cow::Borrowed(english);
    }
    Cow::Borrowed(chinese(key).unwrap_or(english))
}

fn english(key: &'static str) -> &'static str {
    match key {
        "tab_capture" => "Capture",
        "tab_models" => "Models",
        "tab_shortcuts" => "Shortcuts",
        "tab_settings" => "Settings",
        "capture_hint" => "Capture a screen region. OCR results appear below.",
        "capture_png" => "Capture and copy",
        "capture_text" => "Capture and extract",
        "capture_oneline" => "Capture and extract as one line",
        "recent" => "Recent",
        "recent_empty" => "No captures yet.",
        "selected_model" => "Selected model: %{name}",
        "no_model_selected" => "No model selected",
        "status_capturing" => "Capturing...",
        "status_text_copied" => "Recognized text copied",
        "status_png_copied" => "Capture copied as PNG",
        "status_image_copied" => "Image copied",
        "image_unavailable" => "Image unavailable",
        "model" => "Model",
        "install" => "Install",
        "uninstall" => "Uninstall",
        "none" => "(none)",
        "loading" => "(loading)",
        "installing" => "Installing %{name}...",
        "installed" => "Installed %{name}",
        "uninstalled" => "Uninstalled %{name}",
        "select_model_remove" => "Select an installed model to remove",
        "select_model_install" => "Select a model to install",
        "copy" => "Copy",
        "delete" => "Delete",
        "clear_history" => "Clear all",
        "clear_history_confirm" => "Confirm clear",
        "ocr" => "OCR",
        "one_line" => "One line",
        "save" => "Save",
        "saved" => "Saved",
        "shortcuts" => "Shortcuts",
        "shortcuts_running" => "running",
        "shortcuts_running_hint" => "Global shortcuts run while KOCR stays in the tray.",
        "language" => "Language",
        "appearance" => "Appearance",
        "font_size" => "Font size",
        "history_limit" => "History limit",
        "theme" => "Theme",
        "theme_system" => "System",
        "theme_light" => "Light",
        "theme_dark" => "Dark",
        "close_action" => "When closing",
        "close_exit" => "Exit",
        "close_hide" => "Hide to tray",
        "remember_window_state" => "Remember window size and position",
        "preferences_saved" => "Preferences saved",
        "tray_show" => "Show KOCR",
        "tray_quit" => "Quit",
        "tray_failed" => "[-] System tray failed: %{err}",
        _ => key,
    }
}

fn chinese(key: &'static str) -> Option<&'static str> {
    Some(match key {
        "tab_capture" => "截图",
        "tab_models" => "模型",
        "tab_shortcuts" => "快捷键",
        "tab_settings" => "设置",
        "capture_hint" => "截取屏幕区域，识别结果会显示在下方。",
        "capture_png" => "截屏并复制",
        "capture_text" => "截屏并提取",
        "capture_oneline" => "截屏并提取为单行",
        "recent" => "最近结果",
        "recent_empty" => "暂无截图记录。",
        "selected_model" => "选中模型：%{name}",
        "no_model_selected" => "未选择模型",
        "status_capturing" => "正在截图…",
        "status_text_copied" => "已复制识别文本",
        "status_png_copied" => "已复制 PNG 截图",
        "status_image_copied" => "已复制图片",
        "image_unavailable" => "图片不可用",
        "model" => "模型",
        "install" => "安装",
        "uninstall" => "卸载",
        "none" => "（无）",
        "loading" => "（加载中）",
        "installing" => "正在安装 %{name}…",
        "installed" => "已安装 %{name}",
        "uninstalled" => "已卸载 %{name}",
        "select_model_remove" => "请选择要卸载的模型",
        "select_model_install" => "请选择要安装的模型",
        "copy" => "复制",
        "delete" => "删除",
        "clear_history" => "清空全部",
        "clear_history_confirm" => "确认清空",
        "ocr" => "OCR",
        "one_line" => "单行",
        "save" => "保存",
        "saved" => "已保存",
        "shortcuts" => "快捷键",
        "shortcuts_running" => "运行中",
        "shortcuts_running_hint" => "KOCR 留在托盘时，全局快捷键会持续生效。",
        "language" => "语言",
        "appearance" => "外观",
        "font_size" => "字体大小",
        "history_limit" => "历史条数",
        "theme" => "主题",
        "theme_system" => "系统",
        "theme_light" => "浅色",
        "theme_dark" => "深色",
        "close_action" => "关闭窗口时",
        "close_exit" => "退出应用",
        "close_hide" => "隐藏到托盘",
        "remember_window_state" => "记住窗口大小和位置",
        "preferences_saved" => "偏好已保存",
        "tray_show" => "显示 KOCR",
        "tray_quit" => "退出",
        "tray_failed" => "[-] 系统托盘初始化失败：%{err}",
        _ => return None,
    })
}

#[macro_export]
macro_rules! t {
    ($key:literal) => {
        $crate::i18n::translate($key)
    };
    ($key:literal, $($name:ident = $value:expr),+ $(,)?) => {{
        let mut text: String = $crate::i18n::translate($key).into_owned();
        $(
            text = text.replace(
                concat!("%{", stringify!($name), "}"),
                &$value.to_string(),
            );
        )+
        let result: std::borrow::Cow<'static, str> = std::borrow::Cow::Owned(text);
        result
    }};
}
