#[cfg(not(target_os = "linux"))]
compile_error!("kocr only supports Linux.");

use std::env;
use std::path::PathBuf;
use std::process::{Command, ExitCode};

use clap::builder::styling::{AnsiColor, Effects, Styles};
use clap::{Args, CommandFactory, Parser, Subcommand};
use kocr::models;
use kocr::ocr;
use kocr::{AppError, capture};

const EXIT_OK: u8 = 0;
const EXIT_CANCELLED: u8 = 2;
const EXIT_MISSING_DEPENDENCY: u8 = 3;
const EXIT_INVALID_INPUT: u8 = 4;
const EXIT_OCR: u8 = 5;
const EXIT_OUTPUT: u8 = 6;

const CLI_STYLES: Styles = Styles::styled()
    .header(AnsiColor::Green.on_default().effects(Effects::BOLD))
    .usage(AnsiColor::Green.on_default().effects(Effects::BOLD))
    .literal(AnsiColor::Cyan.on_default().effects(Effects::BOLD))
    .placeholder(AnsiColor::Yellow.on_default());

#[derive(Debug, Parser)]
#[command(
    name = "kocr",
    version,
    propagate_version = true,
    about = "Offline OCR tool",
    color = clap::ColorChoice::Always,
    styles = CLI_STYLES,
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<CommandKind>,
}

#[derive(Debug, Subcommand)]
enum CommandKind {
    /// Capture a screen region
    Capture(CaptureArgs),

    /// Check required dependencies
    Doctor,

    /// List available models
    List,

    /// Install a model by ID or name
    Install(models::InstallArgs),

    /// Uninstall a model by ID or name
    Uninstall(models::ProfileArgs),

    /// Select the active OCR model
    Use(models::ProfileArgs),

    /// Open the configuration file
    Config,

    /// Recognize text from an image
    Image(ocr::ImageArgs),

    /// Show configuration and daemon state
    Status,

    /// Show command help
    #[command(name = "help", about = "Show command help")]
    Help,

    /// Show version
    Version,
}

#[derive(Debug, Args)]
struct CaptureArgs {
    /// Output path (optional)
    #[arg(value_name = "PNG")]
    output: Option<PathBuf>,

    /// Recognize the capture and copy text
    #[arg(short = 'o', long = "ocr")]
    ocr: bool,

    /// Merge recognized lines into a single line
    #[arg(long, requires = "ocr")]
    oneline: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::from(EXIT_OK),
        Err(AppError::Cancelled) => ExitCode::from(EXIT_CANCELLED),
        Err(error) => {
            if matches!(
                &error,
                AppError::Model(_) | AppError::Config(_) | AppError::Ocr(_)
            ) {
                eprintln!("\x1b[31m{error}\x1b[0m");
            } else {
                eprintln!("kocr: {error}");
            }
            ExitCode::from(error_code(&error))
        }
    }
}

fn run(cli: Cli) -> Result<(), AppError> {
    match cli.command {
        Some(CommandKind::Capture(args)) => capture::run(args.output, args.ocr, args.oneline),
        Some(CommandKind::Doctor) => run_doctor(),
        Some(CommandKind::List) => models::list().map_err(AppError::Model),
        Some(CommandKind::Install(args)) => {
            models::install(&args.profile, args.path.as_deref()).map_err(AppError::Model)
        }
        Some(CommandKind::Uninstall(args)) => {
            models::uninstall(&args.profile).map_err(AppError::Model)
        }
        Some(CommandKind::Use(args)) => models::use_model(&args.profile).map_err(AppError::Model),
        Some(CommandKind::Config) => models::edit_config().map_err(AppError::Config),
        Some(CommandKind::Image(args)) => ocr::run(args.image, args.oneline).map_err(AppError::Ocr),
        Some(CommandKind::Status) => run_status(),
        Some(CommandKind::Help) => print_help(),
        Some(CommandKind::Version) => {
            println!("kocr {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        None => print_help(),
    }
}

fn print_help() -> Result<(), AppError> {
    Cli::command()
        .print_help()
        .map_err(|error| AppError::Output(format!("could not print help: {error}")))?;
    println!();
    Ok(())
}

fn error_code(error: &AppError) -> u8 {
    match error {
        AppError::Cancelled => EXIT_CANCELLED,
        AppError::MissingDependency(_) => EXIT_MISSING_DEPENDENCY,
        AppError::InvalidInput(_) | AppError::Model(_) => EXIT_INVALID_INPUT,
        AppError::Config(_) => EXIT_OUTPUT,
        AppError::Ocr(_) => EXIT_OCR,
        AppError::Output(_) => EXIT_OUTPUT,
    }
}

fn run_status() -> Result<(), AppError> {
    let config_path = kocr_config::config_path();
    let config = models::load_config().map_err(AppError::Config)?;
    let installed = models::installed_model_names().map_err(AppError::Model)?;
    let shortcuts = config.shortcut.clone();

    println!("config     {}", config_path.display());
    println!("daemon     {}", daemon_state());
    println!(
        "model      {}",
        config.models.select.as_deref().unwrap_or("none")
    );
    println!(
        "installed  {}",
        if installed.is_empty() {
            "none".to_owned()
        } else {
            installed.join(", ")
        }
    );
    println!(
        "shortcuts  copy={} ocr={} oneline={}",
        shortcut_state(shortcuts.copy.as_deref()),
        shortcut_state(shortcuts.ocr.as_deref()),
        shortcut_state(shortcuts.oneline.as_deref()),
    );
    Ok(())
}

fn shortcut_state(shortcut: Option<&str>) -> &str {
    match shortcut {
        Some(shortcut) if !shortcut.trim().is_empty() => shortcut,
        _ => "disabled",
    }
}

fn daemon_state() -> String {
    match Command::new("systemctl")
        .args(["--user", "is-active", "kocr.service"])
        .output()
    {
        Ok(output) => {
            let state = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            if state.is_empty() {
                "unknown".to_owned()
            } else {
                state
            }
        }
        Err(_) => "unknown".to_owned(),
    }
}

fn run_doctor() -> Result<(), AppError> {
    let checks = [
        command_check("spectacle"),
        command_check("wl-copy"),
        command_check("notify-send"),
        command_check("curl"),
        engine_check(),
    ];

    for check in &checks {
        let state = if check.ok { "ok" } else { "missing" };
        println!("[{state}] {:<12} {}", check.name, check.detail);
    }
    if checks.iter().any(|check| !check.ok) {
        return Err(AppError::MissingDependency(
            "Environment check failed; install the missing dependencies and retry".to_owned(),
        ));
    }
    println!("Environment check passed.");
    Ok(())
}

#[derive(Debug)]
struct Check {
    name: &'static str,
    ok: bool,
    detail: String,
}

fn command_check(name: &'static str) -> Check {
    match capture::find_command(name) {
        Some(path) => Check {
            name,
            ok: true,
            detail: path.display().to_string(),
        },
        None => Check {
            name,
            ok: false,
            detail: "not found in PATH".to_owned(),
        },
    }
}

fn engine_check() -> Check {
    match ocr::check() {
        Ok(detail) => Check {
            name: "rten",
            ok: true,
            detail,
        },
        Err(error) => Check {
            name: "rten",
            ok: false,
            detail: error.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::{Cli, CommandKind};
    use clap::Parser;

    #[test]
    fn parses_config() {
        let cli = Cli::try_parse_from(["kocr", "config"]).unwrap();
        assert!(matches!(cli.command, Some(CommandKind::Config)));
    }

    #[test]
    fn parses_status() {
        let cli = Cli::try_parse_from(["kocr", "status"]).unwrap();
        assert!(matches!(cli.command, Some(CommandKind::Status)));
    }

    #[test]
    fn parses_capture_ocr() {
        let cli = Cli::try_parse_from(["kocr", "capture", "-o", "--oneline"]).unwrap();
        let Some(CommandKind::Capture(args)) = cli.command else {
            panic!("expected capture command");
        };
        assert!(args.ocr);
        assert!(args.oneline);
    }

    #[test]
    fn parses_install_path() {
        let cli = Cli::try_parse_from(["kocr", "install", "1", "-p", "/models/ppocrv6-small-r1"])
            .unwrap();
        let Some(CommandKind::Install(args)) = cli.command else {
            panic!("expected install command");
        };
        assert_eq!(args.path, Some(PathBuf::from("/models/ppocrv6-small-r1")));
    }

    #[test]
    fn parses_image() {
        let cli = Cli::try_parse_from(["kocr", "image", "image.png", "--oneline"]).unwrap();
        let Some(CommandKind::Image(args)) = cli.command else {
            panic!("expected image command");
        };
        assert!(args.oneline);
    }

    #[test]
    fn oneline_requires_ocr() {
        assert!(Cli::try_parse_from(["kocr", "capture", "--oneline"]).is_err());
    }
}
