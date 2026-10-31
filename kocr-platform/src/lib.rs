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
pub use linux::{capture_region, copy_clipboard, dependencies};
#[cfg(not(target_os = "linux"))]
pub use unsupported::{capture_region, copy_clipboard, dependencies};

#[derive(Debug, Error)]
pub enum PlatformError {
    #[error("Missing dependency: {0}")]
    MissingDependency(String),
    #[error("{0}")]
    Output(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capture {
    Saved,
    Cancelled,
}

pub fn find_command(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    let names = executable_names(name);
    env::split_paths(&path).find_map(|directory| {
        names
            .iter()
            .map(|name| directory.join(name))
            .find(|candidate| candidate.is_file())
    })
}

fn executable_names(name: &str) -> Vec<String> {
    #[cfg(windows)]
    {
        if std::path::Path::new(name).extension().is_some() {
            return vec![name.to_owned()];
        }
        let extensions = env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_owned());
        let mut names = vec![name.to_owned()];
        names.extend(
            extensions
                .split(';')
                .filter(|extension| !extension.is_empty())
                .map(|extension| format!("{name}{extension}")),
        );
        names
    }
    #[cfg(not(windows))]
    {
        vec![name.to_owned()]
    }
}

pub fn home_dir() -> Option<PathBuf> {
    dirs::home_dir()
}

pub fn data_home() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(|| PathBuf::from(".").join(".local/share"))
}
