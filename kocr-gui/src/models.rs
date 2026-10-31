//! OCR model listing and install progress formatting.

use kocr_model::Progress;

#[derive(Clone)]
pub(crate) struct ModelRow {
    pub(crate) name: String,
    pub(crate) installed: bool,
}

pub(crate) fn load_models() -> Result<Vec<ModelRow>, String> {
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

pub(crate) fn progress_fraction(progress: &Progress) -> f32 {
    match progress.total {
        Some(total) if total > 0 => (progress.downloaded as f32 / total as f32).clamp(0.0, 1.0),
        _ => 0.0,
    }
}

pub(crate) fn progress_text(progress: &Progress) -> String {
    match progress.total {
        Some(total) if total > 0 => {
            let percent = progress.downloaded.saturating_mul(100) / total;
            t!("installing_percent", percent = percent).to_string()
        }
        _ => t!(
            "installing_size",
            size = format!("{:.1}", progress.downloaded as f64 / (1024.0 * 1024.0))
        )
        .to_string(),
    }
}
#[cfg(test)]
mod tests {
    use super::{progress_fraction, progress_text};
    use kocr_model::Progress;

    #[test]
    fn computes_download_fraction() {
        let progress = Progress {
            downloaded: 50,
            total: Some(200),
        };
        assert_eq!(progress_fraction(&progress), 0.25);
    }

    #[test]
    fn formats_install_progress() {
        rust_i18n::set_locale("zh-CN");
        let progress = Progress {
            downloaded: 50,
            total: Some(200),
        };
        assert_eq!(progress_text(&progress), "正在安装 25%");
    }
}
