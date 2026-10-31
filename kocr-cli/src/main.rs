use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::builder::styling::{AnsiColor, Effects, Styles};
use clap::{Args, CommandFactory, Parser, Subcommand};
use comfy_table::{Cell, Color, Table, presets::UTF8_BORDERS_ONLY};
use kocr_core::AppError;
use kocr_core::models;
use kocr_core::ocr;
use kocr_core::platform;

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

    /// Recognize text from an image
    Image(ImageArgs),

    /// Show command help
    #[command(name = "help", about = "Show command help")]
    Help,

    /// Show version
    Version,
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
        Some(CommandKind::Doctor) => run_doctor(),
        Some(CommandKind::List) => run_list(),
        Some(CommandKind::Install(args)) => run_install(args),
        Some(CommandKind::Uninstall(args)) => run_uninstall(args),
        Some(CommandKind::Use(args)) => run_use(args),
        Some(CommandKind::Image(args)) => run_image(args),
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

fn run_list() -> Result<(), AppError> {
    let entries = models::list().map_err(AppError::Model)?;
    println!("config     {}", models::config_path().display());
    println!();
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
    let mut progress_shown = false;
    let result = models::install(&args.profile, args.path.as_deref(), |progress| {
        progress_shown = true;
        print_download_progress(&progress);
    });
    if progress_shown {
        eprintln!();
    }
    let installed = result.map_err(AppError::Model)?;
    if let Some(error) = &installed.config_error {
        eprintln!("\x1b[31mCould not update model configuration: {error}\x1b[0m");
    }
    println!("Installed {}", installed.name);
    println!("Path: {}", display_path(&installed.path));
    Ok(())
}

fn print_download_progress(progress: &models::Progress) {
    match progress.total {
        Some(total) if total > 0 => {
            let percent = progress.downloaded.saturating_mul(100) / total;
            eprint!("\rDownloading {percent}%");
        }
        _ => eprint!(
            "\rDownloading {}",
            format_download_size(progress.downloaded)
        ),
    }
}

fn format_download_size(bytes: u64) -> String {
    const MIB: u64 = 1024 * 1024;
    if bytes >= MIB {
        format!("{:.1} MiB", bytes as f64 / MIB as f64)
    } else {
        format!("{} KiB", bytes / 1024)
    }
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
    let check = engine_check();
    let state = if check.ok { "ok" } else { "missing" };
    println!("[{state}] {:<12} {}", check.name, check.detail);
    if !check.ok {
        return Err(AppError::MissingDependency(
            "Environment check failed; install a model with kocr install and retry".to_owned(),
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
}
