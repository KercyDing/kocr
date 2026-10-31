use std::path::Path;

use super::{Capture, PlatformError};

pub fn capture_region(_output: &Path) -> Result<Capture, PlatformError> {
    Err(PlatformError::MissingDependency(
        "screen capture is not implemented for this platform yet".to_owned(),
    ))
}

pub fn copy_clipboard(_content: &[u8], _mime: &str) -> Result<(), PlatformError> {
    Err(PlatformError::MissingDependency(
        "clipboard access is not implemented for this platform yet".to_owned(),
    ))
}

pub fn dependencies() -> &'static [&'static str] {
    &[]
}
