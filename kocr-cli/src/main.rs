use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use clap::builder::styling::{AnsiColor, Effects, Styles};
use clap::{Args, CommandFactory, Parser, Subcommand};
use comfy_table::{Cell, Color, Table, presets::UTF8_BORDERS_ONLY};
use kocr_core::models;
use kocr_core::ocr;
use kocr_core::platform;
use kocr_core::{AppError, capture};

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
    Install(InstallArgs),

    /// Uninstall a model by ID or name
    Uninstall(ProfileArgs),

    /// Select the active OCR model
    Use(ProfileArgs),

    /// Open the configuration file
    Config,

    /// Recognize text from an image
    Image(ImageArgs),

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

#[derive(Debug, Args)]
struct ProfileArgs {
    /// Model ID or name
    #[arg(value_name = "ID_OR_MODEL")]
    profile: String,
}

#[derive(Debug, Args)]
struct InstallArgs {
    /// Model ID or name
    #[arg(value_name = "ID_OR_MODEL")]
    profile: String,

    /// Parent directory for the model installation
    #[arg(short, long, value_name = "DIRECTORY")]
    path: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct ImageArgs {
    /// Input image path
    #[arg(value_name = "PNG")]
    image: PathBuf,

    /// Merge recognized lines into a single line
    #[arg(long)]
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
        Some(CommandKind::Capture(args)) => run_capture(args),
        Some(CommandKind::Doctor) => run_doctor(),
        Some(CommandKind::List) => run_list(),
        Some(CommandKind::Install(args)) => run_install(args),
        Some(CommandKind::Uninstall(args)) => run_uninstall(args),
        Some(CommandKind::Use(args)) => run_use(args),
        Some(CommandKind::Config) => run_config(),
        Some(CommandKind::Image(args)) => run_image(args),
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
    let config_path = models::config_path();
    let config = models::load_config().map_err(AppError::Config)?;
    let installed = models::installed_model_names().map_err(AppError::Model)?;
    let shortcuts = config.shortcut.clone();

    println!("config     {}", config_path.display());
    println!("daemon     {}", platform::service_state("kocr.service"));
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

fn run_capture(args: CaptureArgs) -> Result<(), AppError> {
    let result = capture::run(args.output, args.ocr, args.oneline)?;
    if let Some(text) = result.text {
        println!("{text}");
    }
    if let Some(path) = result.path {
        println!("{}", path.display());
    }
    Ok(())
}

fn run_list() -> Result<(), AppError> {
    let entries = models::list().map_err(AppError::Model)?;
    let id_width = entries
        .iter()
        .map(|entry| entry.id.to_string().len())
        .max()
        .unwrap_or(1)
        + 1;
    let mut table = Table::new();
    table
        .enforce_styling()
        .load_style(UTF8_BORDERS_ONLY)
        .set_header(["ID", "Model", "Location"]);
    for entry in entries {
        let id = if entry.active {
            format!("*{:>width$}", entry.id, width = id_width - 1)
        } else {
            format!("{:>id_width$}", entry.id)
        };
        if entry.installed {
            table.add_row([
                Cell::new(id),
                Cell::new(entry.name.as_str()).fg(Color::Green),
                Cell::new(display_path(&entry.path)),
            ]);
        } else {
            table.add_row([
                Cell::new(id),
                Cell::new(entry.name.as_str()),
                Cell::new("Not installed"),
            ]);
        }
    }
    println!("{table}");
    Ok(())
}

fn run_install(args: InstallArgs) -> Result<(), AppError> {
    let installed =
        models::install(&args.profile, args.path.as_deref()).map_err(AppError::Model)?;
    if let Some(error) = &installed.config_error {
        eprintln!("\x1b[31mCould not update model configuration: {error}\x1b[0m");
    }
    println!("Installed {}", installed.name);
    println!("Path: {}", display_path(&installed.path));
    Ok(())
}

fn run_uninstall(args: ProfileArgs) -> Result<(), AppError> {
    let name = models::uninstall(&args.profile).map_err(AppError::Model)?;
    println!("Uninstalled {name}");
    Ok(())
}

fn run_use(args: ProfileArgs) -> Result<(), AppError> {
    let name = models::use_model(&args.profile).map_err(AppError::Model)?;
    println!("Using {name}");
    Ok(())
}

fn run_image(args: ImageArgs) -> Result<(), AppError> {
    let text = ocr::recognize(args.image, args.oneline).map_err(AppError::Ocr)?;
    println!("{text}");
    Ok(())
}

fn run_config() -> Result<(), AppError> {
    let path = models::prepare_config().map_err(AppError::Config)?;
    let editor = env::var_os("VISUAL")
        .filter(|value| !value.is_empty())
        .or_else(|| env::var_os("EDITOR").filter(|value| !value.is_empty()))
        .map(PathBuf::from);
    let result = match editor {
        Some(editor) => run_editor(&editor, &path),
        None => platform::open_file(&path).map_err(|error| error.to_string()),
    };
    result.map_err(|error| AppError::Config(models::ModelError::Operation(error)))
}

fn run_editor(editor: &Path, path: &Path) -> Result<(), String> {
    let status = Command::new(editor)
        .arg(path)
        .status()
        .map_err(|error| format!("could not start editor {}: {error}", editor.display()))?;
    if !status.success() {
        return Err(format!("editor {} exited with {status}", editor.display()));
    }
    Ok(())
}

fn display_path(path: &Path) -> String {
    let Some(home) = platform::home_dir() else {
        return path.display().to_string();
    };
    match path.strip_prefix(home) {
        Ok(relative) => format!("~/{}", relative.display()),
        Err(_) => path.display().to_string(),
    }
}

fn run_doctor() -> Result<(), AppError> {
    let mut checks = Vec::new();
    for &dependency in platform::dependencies() {
        checks.push(command_check(dependency));
    }
    checks.push(command_check("curl"));
    checks.push(engine_check());

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
    match platform::find_command(name) {
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
