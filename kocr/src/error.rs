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
    Model(#[from] crate::models::ModelError),

    #[error("Config failed: {0}")]
    Config(crate::models::ModelError),

    #[error("OCR failed: {0}")]
    Ocr(#[from] crate::ocr::OcrError),

    #[error("Output failed: {0}")]
    Output(String),
}
