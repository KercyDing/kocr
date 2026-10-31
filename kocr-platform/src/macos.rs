use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use tempfile::Builder;

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

pub fn copy_clipboard(content: &[u8], mime: &str) -> Result<(), PlatformError> {
    if mime == "image/png" {
        copy_image(content)
    } else {
        copy_text(content)
    }
}

fn copy_text(content: &[u8]) -> Result<(), PlatformError> {
    let pbcopy = find_command("pbcopy").ok_or_else(|| missing("pbcopy"))?;
    let mut child = Command::new(pbcopy)
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| PlatformError::Output(format!("could not start pbcopy: {error}")))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| PlatformError::Output("pbcopy stdin was not available".to_owned()))?;
    stdin
        .write_all(content)
        .map_err(|error| PlatformError::Output(format!("could not write to pbcopy: {error}")))?;
    drop(stdin);
    let status = child
        .wait()
        .map_err(|error| PlatformError::Output(format!("could not wait for pbcopy: {error}")))?;
    if !status.success() {
        return Err(PlatformError::Output(format!(
            "pbcopy exited with {status}"
        )));
    }
    Ok(())
}

fn copy_image(content: &[u8]) -> Result<(), PlatformError> {
    let mut file = Builder::new().suffix(".png").tempfile().map_err(|error| {
        PlatformError::Output(format!("could not create temporary file: {error}"))
    })?;
    file.write_all(content)
        .map_err(|error| PlatformError::Output(format!("could not write image: {error}")))?;
    file.flush()
        .map_err(|error| PlatformError::Output(format!("could not flush image: {error}")))?;

    let osascript = find_command("osascript").ok_or_else(|| missing("osascript"))?;
    let path = file.path().display().to_string();
    let path = path.replace('\\', "\\\\").replace('"', "\\\"");
    let script = format!(
        r#"set the clipboard to (read (POSIX file "{}") as «class PNGf»)"#,
        path
    );
    let status = Command::new(osascript)
        .args(["-e", &script])
        .status()
        .map_err(|error| PlatformError::Output(format!("could not start osascript: {error}")))?;
    if !status.success() {
        return Err(PlatformError::Output(format!(
            "osascript exited with {status}"
        )));
    }
    Ok(())
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
    &["screencapture", "osascript", "pbcopy"]
}
