//! Capture and OCR logic shared by the CLI and the shortcut daemon.

mod config;
mod hash;

pub mod capture;
pub mod error;
pub mod models;
pub mod ocr;
pub mod platform;

pub use error::AppError;
