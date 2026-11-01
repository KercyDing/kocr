use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::{Capture, PlatformError, find_command};

pub fn capture_region(output: &Path) -> Result<Capture, PlatformError> {
    let screencapture = screencapture_path()?;
    let _ = fs::remove_file(output);
    let status = Command::new(screencapture)
        .args(["-i", "-x"])
        .arg(output)
        .status()
        .map_err(|error| {
            PlatformError::Output(format!("could not start screencapture: {error}"))
        })?;

    if output.is_file() {
        if status.success() {
            Ok(Capture::Saved)
        } else {
            Err(PlatformError::Output(format!(
                "screencapture exited with {status}"
            )))
        }
    } else {
        Ok(Capture::Cancelled)
    }
}

fn screencapture_path() -> Result<PathBuf, PlatformError> {
    if let Some(path) = find_command("screencapture") {
        return Ok(path);
    }
    let path = PathBuf::from("/usr/sbin/screencapture");
    path.is_file()
        .then_some(path)
        .ok_or_else(|| missing("screencapture"))
}

fn missing(name: &str) -> PlatformError {
    PlatformError::MissingDependency(format!("{name} not found in PATH"))
}

pub fn dependencies() -> &'static [&'static str] {
    &["screencapture"]
}
