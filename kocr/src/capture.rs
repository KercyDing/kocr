use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use tempfile::TempDir;

use crate::{AppError, ocr};

pub fn run(output: Option<PathBuf>, recognize: bool, oneline: bool) -> Result<(), AppError> {
    let spectacle = require_command("spectacle")?;
    let temp_dir = TempDir::new().map_err(|error| {
        AppError::Output(format!("could not create temporary directory: {error}"))
    })?;
    let capture_path = output
        .clone()
        .unwrap_or_else(|| temp_dir.path().join("capture.png"));

    let release_capture = spectacle_supports_release_capture(&spectacle);
    let status = Command::new(spectacle)
        .args(spectacle_args(release_capture))
        .arg(&capture_path)
        .stderr(Stdio::null())
        .status()
        .map_err(|error| AppError::Output(format!("could not start Spectacle: {error}")))?;

    if !capture_path.is_file() {
        if status.success() {
            return Err(AppError::Cancelled);
        }
        return Err(AppError::Output(format!(
            "Spectacle exited with {status} and produced no screenshot"
        )));
    }
    if !status.success() {
        return Err(AppError::Output(format!("Spectacle exited with {status}")));
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
        copy_text(&text)?;
        println!("{text}");
    } else {
        copy_png(&png)?;
    }
    if let Some(path) = output {
        println!("{}", path.display());
    }
    Ok(())
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

fn require_command(name: &str) -> Result<PathBuf, AppError> {
    find_command(name)
        .ok_or_else(|| AppError::MissingDependency(format!("{name} not found in PATH")))
}

pub fn find_command(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
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

fn copy_png(png: &[u8]) -> Result<(), AppError> {
    copy_clipboard(png, "image/png")
}

fn copy_text(text: &str) -> Result<(), AppError> {
    copy_clipboard(text.as_bytes(), "text/plain;charset=utf-8")
}

fn copy_clipboard(content: &[u8], mime: &str) -> Result<(), AppError> {
    let wl_copy = require_command("wl-copy")?;
    let mut child = Command::new(wl_copy)
        .args(["--type", mime])
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| AppError::Output(format!("could not start wl-copy: {error}")))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| AppError::Output("wl-copy stdin was not available".to_owned()))?;
    stdin
        .write_all(content)
        .map_err(|error| AppError::Output(format!("could not write to wl-copy: {error}")))?;
    drop(stdin);

    let status = child
        .wait()
        .map_err(|error| AppError::Output(format!("could not wait for wl-copy: {error}")))?;
    if !status.success() {
        return Err(AppError::Output(format!("wl-copy exited with {status}")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{spectacle_args, validate_png};

    #[test]
    fn accepts_png() {
        let png = b"\x89PNG\r\n\x1a\nrest";
        assert!(validate_png(png).is_ok());
    }

    #[test]
    fn rejects_short_png() {
        assert!(validate_png(b"\x89PNG").is_err());
    }

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
