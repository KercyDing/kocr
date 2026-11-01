use std::borrow::Cow;

use arboard::{Clipboard, ImageData};

use super::PlatformError;

pub fn copy_clipboard(content: &[u8], mime: &str) -> Result<(), PlatformError> {
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
