#[cfg(not(target_os = "linux"))]
compile_error!("kocr-daemon only supports Linux.");

mod keyboard;

use std::process::ExitCode;

fn main() -> ExitCode {
    match keyboard::run(|recognize, oneline| kocr::capture::run(None, recognize, oneline)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("\x1b[31m{error}\x1b[0m");
            ExitCode::FAILURE
        }
    }
}
