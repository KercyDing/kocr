# KOCR

Offline OCR for desktop.

Recognize text from existing images with the CLI, or capture a screen region with the desktop app on Linux. Results are copied directly to the clipboard.

## Installation

### CLI

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/KercyDing/kocr/main/script.sh)"
```

The installer installs `kocr` (CLI) and an INT8 model. It does not install the daemon, GUI, or desktop packages. No ONNX Runtime required. Supports Arch/CachyOS, Debian/Ubuntu, and Fedora/RHEL.

### GUI

Download `kocr-gui-qt-setup-<version>-<target>.tar.gz` or `kocr-gui-gtk-setup-<version>-<target>.tar.gz` from [Releases](https://github.com/KercyDing/kocr/releases), extract it, and run:

```bash
tar -xzf kocr-gui-qt-setup-*.tar.gz
cd kocr-gui-qt-setup-*/
./setup.sh
```

Use the GTK package instead on GTK-based desktops. The GUI setup installs the CLI, daemon, `kocr-gui` settings window, the matching Qt or GTK runtime, and an INT8 model, and adds a KOCR Settings menu entry.

The GTK package requires GTK 4.16 or newer, so it targets recent distributions such as Debian 13, Ubuntu 25.04, Fedora 42, and Arch. Use the Qt package on older systems.

## Usage

### Existing Image

```bash
kocr image test.png   # Recognize text and print to stdout
```

### OCR Models

```bash
kocr list                      # Show config path and list models
kocr install 1                 # Install by ID or name
kocr install 1 -p <DIRECTORY>  # parent directory for the model
kocr use 1                     # Set active model
kocr uninstall 1               # Remove a model
kocr config                    # Open configuration in your default editor
kocr-gui                       # Edit shortcuts and the active model (GUI setup)
```

`--path` (`-p`) sets the parent directory; kocr appends the model name and stores the absolute path in `config.toml`. The default is `$XDG_DATA_HOME/kocr/models`.

Models are INT8-quantized RTen packages, available in small, medium, and tiny tiers.

## Keyboard Shortcuts

The desktop installer registers a systemd user service with three default shortcuts:

| Shortcut | Action |
|----------|--------|
| `Alt+1`  | Capture and copy PNG |
| `Alt+2`  | Capture, OCR, and copy text |
| `Alt+3`  | Capture, OCR, merge into one line, and copy text |

Change shortcuts with `kocr-gui` or `kocr config`. The daemon reloads the configuration automatically on save.

## Configuration

`kocr config` opens `~/.config/kocr/config.toml` in the editor specified by `VISUAL`, `EDITOR`, or the desktop default.

Example:

```toml
[shortcut]
copy = "Alt+1"
ocr  = "Alt+2"
oneline = "Alt+3"

[models]
select = "ppocrv6-small-int8-r1"

[models.ppocrv6-small-int8-r1]
path = "/home/user/.local/share/kocr/models/ppocrv6-small-int8-r1"
```

Supported modifiers: `Mod`, `Ctrl`, `Alt`, `Shift`.  
Key examples: `A-Z`, `0-9`, `F1-F35`, `Escape`, `Space`, `Slash`.  
Set a shortcut to an empty string to disable it.

## License

[Apache License 2.0](LICENSE)

Third-party notices: [NOTICE](NOTICE)

OCR models are based on PaddleOCR: [LICENSE-PaddleOCR](LICENSE-PaddleOCR).
