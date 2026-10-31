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
            format!("Installing {percent}%")
        }
        _ => format!(
            "Installing {:.1} MiB",
            progress.downloaded as f64 / (1024.0 * 1024.0)
        ),
    }
}
#[cfg(test)]
mod tests {
    use super::progress_fraction;
    use kocr_model::Progress;

    #[test]
    fn computes_download_fraction() {
        let progress = Progress {
            downloaded: 50,
            total: Some(200),
        };
        assert_eq!(progress_fraction(&progress), 0.25);
    }
}
