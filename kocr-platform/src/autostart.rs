//! Launch-at-login integration.
//!
//! The entry always points at the current executable, so re-applying it after
//! an update keeps the registration valid.

use auto_launch::AutoLaunchBuilder;
use std::path::PathBuf;

use super::PlatformError;

const APP_NAME: &str = "KOCR";

fn auto_launch() -> Result<auto_launch::AutoLaunch, PlatformError> {
    let path = executable()?;
    AutoLaunchBuilder::new()
        .set_app_name(APP_NAME)
        .set_app_path(&path.to_string_lossy())
        .build()
        .map_err(|error| PlatformError::Output(format!("could not prepare autostart: {error}")))
}

pub fn autostart_enabled() -> bool {
    auto_launch().is_ok_and(|auto| auto.is_enabled().unwrap_or(false))
}

pub fn set_autostart(enabled: bool) -> Result<(), PlatformError> {
    let auto = auto_launch()?;
    if enabled {
        auto.enable()
    } else {
        auto.disable()
    }
    .map_err(|error| {
        PlatformError::Output(format!("could not update the autostart entry: {error}"))
    })
}

fn executable() -> Result<PathBuf, PlatformError> {
    let executable = std::env::current_exe().map_err(|error| {
        PlatformError::Output(format!("could not locate the executable: {error}"))
    })?;
    #[cfg(target_os = "macos")]
    if let Some(bundle) = bundle_path(&executable) {
        return Ok(bundle);
    }
    Ok(executable)
}

/// A login item has to point at the app bundle, not the binary inside it.
#[cfg(target_os = "macos")]
fn bundle_path(executable: &std::path::Path) -> Option<PathBuf> {
    let mut bundle = PathBuf::new();
    for component in executable.components() {
        bundle.push(component);
        if component.as_os_str().to_string_lossy().ends_with(".app") {
            return Some(bundle);
        }
    }
    None
}
