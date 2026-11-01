use std::borrow::Cow;
#[cfg(target_os = "linux")]
use std::io::Write;

use arboard::{Clipboard, ImageData};

use super::PlatformError;

pub fn copy_clipboard(content: &[u8], mime: &str) -> Result<(), PlatformError> {
    #[cfg(target_os = "linux")]
    if is_wayland()
        && matches!(
            mime,
            "image/png" | "text/plain" | "text/plain;charset=utf-8"
        )
        && copy_with_wl_copy(content, mime).is_ok()
    {
        return Ok(());
    }

    copy_with_arboard(content, mime)
}

fn copy_with_arboard(content: &[u8], mime: &str) -> Result<(), PlatformError> {
    let mut clipboard = Clipboard::new()
        .map_err(|error| PlatformError::Output(format!("could not open clipboard: {error}")))?;

    match mime {
        "text/plain" | "text/plain;charset=utf-8" => {
            let text = std::str::from_utf8(content)
                .map_err(|error| PlatformError::Output(format!("invalid UTF-8 text: {error}")))?;
            clipboard
                .set_text(text)
                .map_err(|error| PlatformError::Output(format!("could not copy text: {error}")))?;
        }
        "image/png" => {
            let image = image::load_from_memory(content)
                .map_err(|error| PlatformError::Output(format!("invalid PNG: {error}")))?
                .into_rgba8();
            let data = ImageData {
                width: image.width() as usize,
                height: image.height() as usize,
                bytes: Cow::Owned(image.into_raw()),
            };
            clipboard
                .set_image(data)
                .map_err(|error| PlatformError::Output(format!("could not copy image: {error}")))?;
        }
        other => {
            return Err(PlatformError::Output(format!(
                "unsupported clipboard MIME type: {other}"
            )));
        }
    }

    Ok(())
}

#[cfg(target_os = "linux")]
fn is_wayland() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some_and(|value| !value.is_empty())
}

#[cfg(target_os = "linux")]
fn copy_with_wl_copy(content: &[u8], mime: &str) -> Result<(), ()> {
    use std::process::{Command, Stdio};

    let mut command = Command::new("wl-copy");
    command.arg("--type").arg(mime);
    let mut child = command.stdin(Stdio::piped()).spawn().map_err(|_| ())?;
    let mut stdin = child.stdin.take().ok_or(())?;
    if stdin.write_all(content).is_err() {
        let _ = child.kill();
        return Err(());
    }
    drop(stdin);

    // wl-copy remains alive as the clipboard provider after stdin closes.
    Ok(())
}
