use std::path::Path;

use super::Capture;
use crate::AppError;

pub fn capture_region(_output: &Path) -> Result<Capture, AppError> {
    Err(AppError::MissingDependency(
        "screen capture is not implemented for this platform yet".to_owned(),
    ))
}

pub fn copy_clipboard(_content: &[u8], _mime: &str) -> Result<(), AppError> {
    Err(AppError::MissingDependency(
        "clipboard access is not implemented for this platform yet".to_owned(),
    ))
}

pub fn open_file(_path: &Path) -> Result<(), String> {
    Err(super::NO_OPENER.to_owned())
}

pub fn daemon_state() -> String {
    "unknown".to_owned()
}

pub fn dependencies() -> &'static [&'static str] {
    &[]
}
