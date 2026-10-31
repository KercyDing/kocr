use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::{Capture, PlatformError, find_command};

pub fn capture_region(output: &Path) -> Result<Capture, PlatformError> {
    let spectacle = require_command("spectacle")?;
    let release_capture = spectacle_supports_release_capture(&spectacle);
    let status = Command::new(spectacle)
        .args(spectacle_args(release_capture))
        .arg(output)
        .stderr(Stdio::null())
        .status()
        .map_err(|error| PlatformError::Output(format!("could not start Spectacle: {error}")))?;

    if !output.is_file() {
        if status.success() {
            return Ok(Capture::Cancelled);
        }
        return Err(PlatformError::Output(format!(
            "Spectacle exited with {status} and produced no screenshot"
        )));
    }
    if !status.success() {
        return Err(PlatformError::Output(format!(
            "Spectacle exited with {status}"
        )));
    }
    Ok(Capture::Saved)
}

pub fn copy_clipboard(content: &[u8], mime: &str) -> Result<(), PlatformError> {
    let wl_copy = require_command("wl-copy")?;
    let mut child = Command::new(wl_copy)
        .args(["--type", mime])
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| PlatformError::Output(format!("could not start wl-copy: {error}")))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| PlatformError::Output("wl-copy stdin was not available".to_owned()))?;
    stdin
        .write_all(content)
        .map_err(|error| PlatformError::Output(format!("could not write to wl-copy: {error}")))?;
    drop(stdin);

    let status = child
        .wait()
        .map_err(|error| PlatformError::Output(format!("could not wait for wl-copy: {error}")))?;
    if !status.success() {
        return Err(PlatformError::Output(format!(
            "wl-copy exited with {status}"
        )));
    }
    Ok(())
}

pub fn dependencies() -> &'static [&'static str] {
    &["spectacle", "wl-copy", "notify-send"]
}

fn require_command(name: &str) -> Result<PathBuf, PlatformError> {
    find_command(name)
        .ok_or_else(|| PlatformError::MissingDependency(format!("{name} not found in PATH")))
}

fn spectacle_supports_release_capture(spectacle: &Path) -> bool {
    const OPTION: &[u8] = b"--release-capture";

    Command::new(spectacle)
        .arg("--help")
        .output()
        .is_ok_and(|output| {
            output
                .stdout
                .windows(OPTION.len())
                .chain(output.stderr.windows(OPTION.len()))
                .any(|window| window == OPTION)
        })
}

fn spectacle_args(release_capture: bool) -> Vec<&'static str> {
    let mut args = vec!["--region", "--background", "--nonotify"];
    if release_capture {
        args.push("--release-capture");
    }
    args.push("--output");
    args
}

#[cfg(test)]
mod tests {
    use super::spectacle_args;

    #[test]
    fn uses_release_capture_when_supported() {
        assert_eq!(
            spectacle_args(true),
            vec![
                "--region",
                "--background",
                "--nonotify",
                "--release-capture",
                "--output"
            ]
        );
    }

    #[test]
    fn omits_release_capture_when_unsupported() {
        assert_eq!(
            spectacle_args(false),
            vec!["--region", "--background", "--nonotify", "--output"]
        );
    }
}
