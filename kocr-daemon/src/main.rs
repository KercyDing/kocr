mod platform;

use std::process::ExitCode;

fn main() -> ExitCode {
    match platform::run(|recognize, oneline| kocr_core::capture::run(None, recognize, oneline)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("\x1b[31m{error}\x1b[0m");
            ExitCode::FAILURE
        }
    }
}
