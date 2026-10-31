use std::fs;
use std::io;
use std::path::Path;

use sha2::{Digest, Sha256};

pub(crate) fn file_sha256(path: &Path) -> io::Result<String> {
    Ok(hex_sha256(&fs::read(path)?))
}

pub(crate) fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
