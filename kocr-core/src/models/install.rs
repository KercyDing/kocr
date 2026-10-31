use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;
use zip::ZipArchive;

use super::{
    ModelError, default_model_path, load_index, model_path, record_install, resolve_profile,
    sync_config,
};

pub fn run(selector: &str, path: Option<&Path>) -> Result<(), ModelError> {
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
    let curl = find_command("curl")
        .ok_or_else(|| ModelError::Operation("curl not found in PATH".to_owned()))?;
    let status = Command::new(curl)
        .args(["-fL", "--retry", "3", "--progress-bar", "--output"])
        .arg(&archive_path)
        .arg(profile.url)
        .status()
        .map_err(|error| ModelError::Operation(format!("could not start curl: {error}")))?;
    if !status.success() {
        return Err(ModelError::Operation(format!("download failed: {status}")));
    }
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
    if let Err(error) = record_install(name, &destination) {
        eprintln!("\x1b[31mCould not update model configuration: {error}\x1b[0m");
    }
    println!("Installed {name}");
    println!("Path: {}", display_path(&destination));
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

fn find_command(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

fn display_path(path: &Path) -> String {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return path.display().to_string();
    };
    match path.strip_prefix(home) {
        Ok(relative) => format!("~/{}", relative.display()),
        Err(_) => path.display().to_string(),
    }
}
