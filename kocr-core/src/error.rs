use kocr_platform::PlatformError;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("Capture cancelled")]
    Cancelled,

    #[error("Missing dependency: {0}")]
    MissingDependency(String),

    #[error("Invalid input: {0}")]
    InvalidInput(String),

    #[error("Model failed: {0}")]
    Model(#[from] kocr_model::ModelError),

    #[error("Config failed: {0}")]
    Config(kocr_model::ModelError),

    #[error("OCR failed: {0}")]
    Ocr(#[from] kocr_ocr::OcrError),

    #[error("Output failed: {0}")]
    Output(String),
}

impl From<PlatformError> for AppError {
    fn from(error: PlatformError) -> Self {
        match error {
            PlatformError::MissingDependency(message) => Self::MissingDependency(message),
            PlatformError::Output(message) | PlatformError::Operation(message) => {
                Self::Output(message)
            }
        }
    }
}
