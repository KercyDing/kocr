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

pub fn service_state(_unit: &str) -> String {
    "unknown".to_owned()
}

pub fn service_start(unit: &str) -> Result<(), PlatformError> {
    Err(PlatformError::Operation(format!(
        "could not start {unit}: service control is not implemented for this platform yet"
    )))
}

pub fn service_stop(unit: &str) -> Result<(), PlatformError> {
    Err(PlatformError::Operation(format!(
        "could not stop {unit}: service control is not implemented for this platform yet"
    )))
}

pub fn service_install(unit: &str, _executable: &Path) -> Result<(), PlatformError> {
    Err(PlatformError::Operation(format!(
        "could not install {unit}: service control is not implemented for this platform yet"
    )))
}

pub fn service_enabled(_unit: &str) -> bool {
    false
}

pub fn service_enable(unit: &str) -> Result<(), PlatformError> {
    Err(PlatformError::Operation(format!(
        "could not enable {unit}: service control is not implemented for this platform yet"
    )))
}

pub fn service_disable(unit: &str) -> Result<(), PlatformError> {
    Err(PlatformError::Operation(format!(
        "could not disable {unit}: service control is not implemented for this platform yet"
    )))
}

pub fn dependencies() -> &'static [&'static str] {
    &[]
}
