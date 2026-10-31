//! Capture and OCR orchestration shared by the CLI and the shortcut daemon.

pub mod capture;
pub mod error;

pub use error::AppError;
pub use kocr_model as models;
pub use kocr_ocr as ocr;
pub use kocr_platform as platform;
