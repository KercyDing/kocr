use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use tempfile::TempDir;
use zip::ZipArchive;

use super::{
    ModelError, default_model_path, load_index, model_path, record_install, resolve_profile,
    sync_config,
};

const USER_AGENT: &str = concat!("kocr/", env!("CARGO_PKG_VERSION"));
const DOWNLOAD_ATTEMPTS: u8 = 3;
const PROGRESS_STEP: u64 = 1024 * 1024;

#[derive(Debug, Clone, Copy)]
pub struct Progress {
    pub downloaded: u64,
    pub total: Option<u64>,
}

pub struct InstallResult {
    pub name: String,
    pub path: PathBuf,
    pub config_error: Option<String>,
}

pub fn run<F>(
    selector: &str,
    path: Option<&Path>,
    mut on_progress: F,
) -> Result<InstallResult, ModelError>
where
    F: FnMut(Progress),
{
    sync_config()?;
    let index = load_index()?;
    let (name, profile) = resolve_profile(&index, selector)?;
    if model_path(name)?.join("manifest.toml").is_file() {
        return Err(ModelError::Operation(format!(
            "{name} is already installed"
        )));
    }
    let destination = match path {
        Some(path) => std::path::absolute(path)
            .map_err(|error| {
                ModelError::Operation(format!("could not resolve model path: {error}"))
            })?
            .join(name),
        None => default_model_path(name),
    };
    if destination.exists() {
        return Err(ModelError::Operation(format!(
            "model destination already exists: {}",
            destination.display()
        )));
    }
    let model_root = destination
        .parent()
        .ok_or_else(|| ModelError::Operation("invalid model path".to_owned()))?;
    fs::create_dir_all(model_root).map_err(|error| {
        ModelError::Operation(format!("could not create model directory: {error}"))
    })?;
    let temporary = TempDir::new().map_err(|error| {
        ModelError::Operation(format!("could not create temporary directory: {error}"))
    })?;
    let archive_path = temporary.path().join("model.zip");
    download(profile.url, &archive_path, &mut on_progress)?;
    let actual = crate::hash::file_sha256(&archive_path)
        .map_err(|error| ModelError::Operation(format!("could not read archive: {error}")))?;
    if actual != profile.sha256 {
        return Err(ModelError::Operation(format!(
            "SHA-256 mismatch: expected {}, got {actual}",
            profile.sha256
        )));
    }
    let staging = tempfile::Builder::new()
        .prefix(".kocr-extract-")
        .tempdir_in(model_root)
        .map_err(|error| {
            ModelError::Operation(format!("could not create extraction directory: {error}"))
        })?;
    let package = staging.path().join("model");
    fs::create_dir(&package).map_err(|error| {
        ModelError::Operation(format!("could not create extraction directory: {error}"))
    })?;
    extract(&archive_path, &package)?;
    write_manifest(&package, name)?;
    fs::rename(&package, &destination).map_err(|error| {
        ModelError::Operation(format!("could not install model profile: {error}"))
    })?;
    let config_error = record_install(name, &destination)
        .err()
        .map(|error| error.to_string());
    Ok(InstallResult {
        name: name.to_owned(),
        path: destination,
        config_error,
    })
}

fn download<F>(url: &str, path: &Path, on_progress: &mut F) -> Result<(), ModelError>
where
    F: FnMut(Progress),
{
    let mut last_error = String::new();
    for attempt in 1..=DOWNLOAD_ATTEMPTS {
        match download_once(url, path, on_progress) {
            Ok(()) => return Ok(()),
            Err(error) => {
                last_error = error;
                if attempt < DOWNLOAD_ATTEMPTS {
                    thread::sleep(Duration::from_secs(u64::from(attempt)));
                }
            }
        }
    }
    Err(ModelError::Operation(format!(
        "could not download model after {DOWNLOAD_ATTEMPTS} attempts: {last_error}"
    )))
}

fn download_once<F>(url: &str, path: &Path, on_progress: &mut F) -> Result<(), String>
where
    F: FnMut(Progress),
{
    let mut response = ureq::get(url)
        .header("User-Agent", USER_AGENT)
        .call()
        .map_err(|error| format!("could not download model: {error}"))?;
    let total = response.body().content_length();
    let mut archive =
        File::create(path).map_err(|error| format!("could not create model archive: {error}"))?;
    let mut reader = response.body_mut().as_reader();
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut downloaded = 0_u64;
    let mut reported = 0_u64;
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|error| format!("could not download model: {error}"))?;
        if read == 0 {
            break;
        }
        archive
            .write_all(&buffer[..read])
            .map_err(|error| format!("could not write model archive: {error}"))?;
        downloaded += read as u64;
        if downloaded - reported >= PROGRESS_STEP || Some(downloaded) == total {
            on_progress(Progress { downloaded, total });
            reported = downloaded;
        }
    }
    if reported != downloaded {
        on_progress(Progress { downloaded, total });
    }
    Ok(())
}

fn extract(archive_path: &Path, destination: &Path) -> Result<(), ModelError> {
    let file = File::open(archive_path)
        .map_err(|error| ModelError::Operation(format!("could not open archive: {error}")))?;
    let mut archive = ZipArchive::new(file)
        .map_err(|error| ModelError::Operation(format!("could not read archive: {error}")))?;
    let mut det = false;
    let mut rec = false;
    let mut dict = false;
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| ModelError::Operation(format!("could not read archive: {error}")))?;
        if entry.is_dir() {
            continue;
        }
        let Some(path) = entry.enclosed_name() else {
            return Err(ModelError::Operation(
                "archive contains an unsafe path".to_owned(),
            ));
        };
        if path.components().count() != 1 {
            return Err(ModelError::Operation(format!(
                "unexpected model path: {}",
                path.display()
            )));
        }
        let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
            return Err(ModelError::Operation(
                "archive contains an invalid file name".to_owned(),
            ));
        };
        let seen = match file_name {
            "det.rten" => &mut det,
            "rec.rten" => &mut rec,
            "dict.txt" => &mut dict,
            _ => {
                return Err(ModelError::Operation(format!(
                    "unexpected model file: {file_name}"
                )));
            }
        };
        if *seen {
            return Err(ModelError::Operation(format!(
                "duplicate model file: {file_name}"
            )));
        }
        *seen = true;
        let mut output = File::create(destination.join(file_name)).map_err(|error| {
            ModelError::Operation(format!("could not extract model file: {error}"))
        })?;
        io::copy(&mut entry, &mut output).map_err(|error| {
            ModelError::Operation(format!("could not extract model file: {error}"))
        })?;
    }
    if !(det && rec && dict) {
        return Err(ModelError::Operation(
            "model archive is incomplete".to_owned(),
        ));
    }
    Ok(())
}

fn write_manifest(package: &Path, name: &str) -> Result<(), ModelError> {
    let charset_path = package.join("dict.txt");
    let charset = fs::read(&charset_path)
        .map_err(|error| ModelError::Operation(format!("could not read charset: {error}")))?;
    let text = std::str::from_utf8(&charset)
        .map_err(|error| ModelError::Operation(format!("charset is not UTF-8: {error}")))?;
    let mut count = 0;
    for line in text.lines() {
        if line.chars().count() != 1 {
            return Err(ModelError::Operation(format!(
                "charset entry is not one character: {line:?}"
            )));
        }
        count += 1;
    }
    if count == 0 {
        return Err(ModelError::Operation("charset is empty".to_owned()));
    }
    let det_sha256 = crate::hash::file_sha256(&package.join("det.rten"))
        .map_err(|error| ModelError::Operation(format!("could not read detector: {error}")))?;
    let rec_sha256 = crate::hash::file_sha256(&package.join("rec.rten"))
        .map_err(|error| ModelError::Operation(format!("could not read recognizer: {error}")))?;
    let manifest = format!(
        "format = 1\nprofile = \"{name}\"\ncharset = \"dict.txt\"\ncharset_sha256 = \"{}\"\ncharset_count = {count}\n\n[det]\nmodel = \"det.rten\"\nsha256 = \"{det_sha256}\"\n\n[rec]\nmodel = \"rec.rten\"\nsha256 = \"{rec_sha256}\"\n",
        crate::hash::hex_sha256(&charset)
    );
    fs::write(package.join("manifest.toml"), manifest)
        .map_err(|error| ModelError::Operation(format!("could not write model manifest: {error}")))
}
