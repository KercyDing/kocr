mod model;

use std::path::{Path, PathBuf};

use clap::Args;
use rusto::{
    DetectTextResult, ImageSource, InitializeConfig, OcrRunOptions, OptimizationOptions,
    OutputGranularity, RustO, TextRecognizer,
};
use thiserror::Error;

use model::Model;

// Tuned against PP-OCRv6 screenshots. The lower thresholds keep bullet/number
// prefixes that the default detector drops; the crop padding keeps glyphs from
// being clipped at box edges. text_score filters the resulting zero-score boxes.
const DET_THRESH: f32 = 0.15;
const DET_BOX_THRESH: f32 = 0.2;
const DET_UNCLIP_RATIO: f32 = 1.4;
const DET_LIMIT_SIDE: i32 = 960;
const DET_MAX_SIDE: f32 = 960.0;
const CROP_PADDING_X: f32 = 0.06;
const CROP_PADDING_Y: f32 = 0.05;
const TEXT_SCORE: f32 = 0.1;

#[derive(Debug, Args)]
pub(crate) struct ImageArgs {
    /// Input image path
    #[arg(value_name = "PNG")]
    pub(crate) image: PathBuf,

    /// Merge recognized lines into a single line
    #[arg(long)]
    pub(crate) oneline: bool,
}

#[derive(Debug, Error)]
pub enum OcrError {
    #[error("model is not installed: {0}")]
    ModelNotInstalled(PathBuf),

    #[error("model manifest is invalid: {0}")]
    Manifest(String),

    #[error("model selection failed: {0}")]
    ModelSelection(String),

    #[error("model file is invalid: {0}")]
    ModelFile(String),

    #[error("image could not be read: {0}")]
    Image(String),

    #[error("OCR engine error: {0}")]
    Engine(#[from] rusto::EngineError),
}

pub fn run(image_path: PathBuf, oneline: bool) -> Result<(), OcrError> {
    let text = recognize(image_path, oneline)?;
    println!("{text}");
    Ok(())
}

pub fn recognize(image_path: PathBuf, oneline: bool) -> Result<String, OcrError> {
    let (_, _, model) = selected_model()?;
    let config = engine_config(&model);
    let mut ocr = RustO::initialize(config.clone())?;
    let options = OcrRunOptions {
        output: OutputGranularity::Lines,
        text_score: Some(TEXT_SCORE),
        ..Default::default()
    };
    let mut lines = match ocr.detect_text(&ImageSource::Path(image_path.clone()), &options)? {
        DetectTextResult::Structured(items) => items
            .into_iter()
            .map(|item| item.text)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>(),
        DetectTextResult::Spatial(text) => text.lines().map(str::to_owned).collect(),
    };
    if lines.is_empty() {
        lines.push(recognize_whole(&config, &image_path)?);
    }
    Ok(join_lines(&lines, oneline))
}

pub(crate) fn check() -> Result<String, OcrError> {
    let (profile, model_dir, model) = selected_model()?;
    RustO::initialize(engine_config(&model))?;
    Ok(format!("rten, {profile} ({})", model_dir.display()))
}

fn selected_model() -> Result<(String, PathBuf, Model), OcrError> {
    crate::models::sync_config().map_err(|error| OcrError::ModelSelection(error.to_string()))?;
    let profile = crate::models::selected_profile()
        .map_err(|error| OcrError::ModelSelection(error.to_string()))?;
    let model_dir = crate::models::model_path(&profile)
        .map_err(|error| OcrError::ModelSelection(error.to_string()))?;
    if !model_dir.is_dir() {
        return Err(OcrError::ModelNotInstalled(model_dir));
    }
    let model = model::load(&model_dir)?;
    Ok((profile, model_dir, model))
}

fn engine_config(model: &Model) -> InitializeConfig {
    InitializeConfig::ppv6(model.det.clone(), model.rec.clone(), model.charset.clone())
        .with_det_thresh(DET_THRESH)
        .with_det_box_thresh(DET_BOX_THRESH)
        .with_unclip_ratio(DET_UNCLIP_RATIO)
        .with_limit_side_len(DET_LIMIT_SIDE)
        .with_limit_type("max")
        .with_use_dilation(false)
        .with_max_side_len(DET_MAX_SIDE)
        .with_optimization(
            OptimizationOptions::default().with_crop_padding(CROP_PADDING_X, CROP_PADDING_Y),
        )
}

fn recognize_whole(config: &InitializeConfig, image_path: &Path) -> Result<String, OcrError> {
    let mut recognizer = TextRecognizer::new(config.rec.clone())?;
    let image = rusto::image_impl::imread(image_path)
        .map_err(|error| OcrError::Image(error.to_string()))?;
    let output = recognizer.run(&[image], false)?;
    Ok(output.txts.into_iter().next().unwrap_or_default())
}

fn join_lines(lines: &[String], oneline: bool) -> String {
    if !oneline {
        return lines.join("\n");
    }

    let mut text = String::new();
    for line in lines {
        if needs_line_space(&text, line) {
            text.push(' ');
        }
        text.push_str(line);
    }
    text
}

fn needs_line_space(left: &str, right: &str) -> bool {
    let Some(left) = left.chars().next_back() else {
        return false;
    };
    let Some(right) = right.chars().next() else {
        return false;
    };
    if left.is_whitespace() || right.is_whitespace() {
        return false;
    }
    if is_cjk(left) || is_cjk(right) {
        return false;
    }
    !matches!(left, '(' | '[' | '{' | '-' | '/' | '—')
        && !matches!(
            right,
            ',' | '.' | ';' | ':' | '!' | '?' | '%' | ')' | ']' | '}' | '\'' | '’'
        )
}

fn is_cjk(character: char) -> bool {
    matches!(
        character as u32,
        0x2E80..=0x303F
            | 0x3040..=0x30FF
            | 0x31F0..=0x31FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xF900..=0xFAFF
            | 0xFF01..=0xFF60
            | 0x20000..=0x2FA1F
            | 0x30000..=0x323AF
    )
}

#[cfg(test)]
mod tests {
    use super::join_lines;

    #[test]
    fn joins_recognized_lines() {
        let english = vec!["first line".to_owned(), "second line".to_owned()];
        assert_eq!(join_lines(&english, false), "first line\nsecond line");
        assert_eq!(join_lines(&english, true), "first line second line");

        let chinese = vec!["中文第一行".to_owned(), "中文第二行".to_owned()];
        assert_eq!(join_lines(&chinese, true), "中文第一行中文第二行");
    }

    #[test]
    fn joins_mixed_text() {
        assert_eq!(
            join_lines(&["version 1".to_owned(), ".0 released".to_owned()], true),
            "version 1.0 released"
        );
        assert_eq!(
            join_lines(&["cross-".to_owned(), "platform".to_owned()], true),
            "cross-platform"
        );
        assert_eq!(
            join_lines(&["支持 Rust".to_owned(), "language 开发".to_owned()], true),
            "支持 Rust language 开发"
        );
    }
}
