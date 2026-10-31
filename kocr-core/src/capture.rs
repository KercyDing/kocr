use std::fs;
use std::path::PathBuf;

use tempfile::TempDir;

use crate::platform::{self, Capture};
use crate::{AppError, ocr};

pub fn run(output: Option<PathBuf>, recognize: bool, oneline: bool) -> Result<(), AppError> {
    let temp_dir = TempDir::new().map_err(|error| {
        AppError::Output(format!("could not create temporary directory: {error}"))
    })?;
    let capture_path = output
        .clone()
        .unwrap_or_else(|| temp_dir.path().join("capture.png"));

    if platform::capture_region(&capture_path)? == Capture::Cancelled {
        return Err(AppError::Cancelled);
    }

    let png = fs::read(&capture_path).map_err(|error| {
        AppError::InvalidInput(format!(
            "could not read {}: {error}",
            capture_path.display()
        ))
    })?;
    validate_png(&png)?;

    if recognize {
        let text = ocr::recognize(capture_path, oneline)?;
        platform::copy_clipboard(text.as_bytes(), "text/plain;charset=utf-8")?;
        println!("{text}");
    } else {
        platform::copy_clipboard(&png, "image/png")?;
    }
    if let Some(path) = output {
        println!("{}", path.display());
    }
    Ok(())
}

fn validate_png(bytes: &[u8]) -> Result<(), AppError> {
    const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
    if bytes.len() <= PNG_SIGNATURE.len() {
        return Err(AppError::InvalidInput(
            "captured PNG is empty or truncated".to_owned(),
        ));
    }
    if !bytes.starts_with(PNG_SIGNATURE) {
        return Err(AppError::InvalidInput(
            "captured file does not have a PNG signature".to_owned(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate_png;

    #[test]
    fn accepts_png() {
        let png = b"\x89PNG\r\n\x1a\nrest";
        assert!(validate_png(png).is_ok());
    }

    #[test]
    fn rejects_short_png() {
        assert!(validate_png(b"\x89PNG").is_err());
    }
}
