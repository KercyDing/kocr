use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;

use super::OcrError;

#[derive(Debug, Deserialize)]
pub(crate) struct Manifest {
    pub(crate) profile: String,
    pub(crate) charset: String,
    pub(crate) charset_sha256: String,
    pub(crate) charset_count: usize,
    pub(crate) det: TensorManifest,
    pub(crate) rec: TensorManifest,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TensorManifest {
    pub(crate) model: String,
    pub(crate) sha256: String,
}

#[derive(Debug)]
pub(crate) struct Model {
    pub(crate) det: PathBuf,
    pub(crate) rec: PathBuf,
    pub(crate) charset: PathBuf,
}

pub(crate) fn load(model_dir: &Path) -> Result<Model, OcrError> {
    let manifest = read_manifest(model_dir)?;
    validate_manifest(&manifest)?;
    let charset = checked_relative_path(model_dir, &manifest.charset)?;
    verify_charset(&charset, &manifest)?;
    let det = checked_relative_path(model_dir, &manifest.det.model)?;
    let rec = checked_relative_path(model_dir, &manifest.rec.model)?;
    verify_file(&det, &manifest.det.sha256)?;
    verify_file(&rec, &manifest.rec.sha256)?;
    Ok(Model { det, rec, charset })
}

fn read_manifest(model_dir: &Path) -> Result<Manifest, OcrError> {
    let path = model_dir.join("manifest.toml");
    let content = fs::read_to_string(&path).map_err(|error| {
        OcrError::Manifest(format!("could not read {}: {error}", path.display()))
    })?;
    toml::from_str(&content)
        .map_err(|error| OcrError::Manifest(format!("could not parse {}: {error}", path.display())))
}

fn validate_manifest(manifest: &Manifest) -> Result<(), OcrError> {
    if manifest.profile.is_empty() {
        return Err(OcrError::Manifest(
            "profile name cannot be empty".to_owned(),
        ));
    }
    if manifest.charset.is_empty() || manifest.charset_count == 0 {
        return Err(OcrError::Manifest("charset is not configured".to_owned()));
    }
    Ok(())
}

fn checked_relative_path(model_dir: &Path, value: &str) -> Result<PathBuf, OcrError> {
    let relative = Path::new(value);
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(OcrError::Manifest(format!("unsafe model path: {value}")));
    }
    Ok(model_dir.join(relative))
}

fn verify_charset(path: &Path, manifest: &Manifest) -> Result<(), OcrError> {
    let content = fs::read(path).map_err(|error| {
        OcrError::ModelFile(format!("could not read {}: {error}", path.display()))
    })?;
    let actual = kocr_model::hash::hex_sha256(&content);
    if actual != manifest.charset_sha256 {
        return Err(OcrError::ModelFile(format!(
            "charset SHA-256 mismatch: expected {}, got {actual}",
            manifest.charset_sha256
        )));
    }
    let text = String::from_utf8(content)
        .map_err(|error| OcrError::ModelFile(format!("charset is not UTF-8: {error}")))?;
    let mut count = 0;
    for line in text.lines() {
        if line.chars().count() != 1 {
            return Err(OcrError::ModelFile(format!(
                "charset entry is not one character: {line:?}"
            )));
        }
        count += 1;
    }
    if count != manifest.charset_count {
        return Err(OcrError::ModelFile(format!(
            "charset count mismatch: expected {}, got {count}",
            manifest.charset_count
        )));
    }
    Ok(())
}

fn verify_file(path: &Path, expected: &str) -> Result<(), OcrError> {
    let actual = kocr_model::hash::file_sha256(path).map_err(|error| {
        OcrError::ModelFile(format!("could not read {}: {error}", path.display()))
    })?;
    if actual != expected {
        return Err(OcrError::ModelFile(format!(
            "SHA-256 mismatch for {}: expected {expected}, got {actual}",
            path.display()
        )));
    }
    Ok(())
}
