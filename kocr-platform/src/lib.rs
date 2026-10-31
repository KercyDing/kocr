//! Platform integration shared by kocr frontends.
//!
//! Only module selection in this file is conditional. Callers use the same
//! functions on every platform.

use std::env;
use std::path::PathBuf;

use thiserror::Error;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(not(target_os = "linux"))]
mod unsupported;

#[cfg(target_os = "linux")]
pub use linux::{
    capture_region, copy_clipboard, dependencies, open_file, service_start, service_state,
    service_stop,
};
#[cfg(not(target_os = "linux"))]
pub use unsupported::{
    capture_region, copy_clipboard, dependencies, open_file, service_start, service_state,
    service_stop,
};

const NO_OPENER: &str = "no text editor found; set VISUAL or EDITOR and retry";

#[derive(Debug, Error)]
pub enum PlatformError {
    #[error("Missing dependency: {0}")]
    MissingDependency(String),
    #[error("{0}")]
    Output(String),
    #[error("{0}")]
    Operation(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capture {
    Saved,
    Cancelled,
}

pub fn find_command(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

pub fn home_dir() -> Option<PathBuf> {
    dirs::home_dir()
}

pub fn data_home() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(|| PathBuf::from(".").join(".local/share"))
}
