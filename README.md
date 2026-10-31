# KOCR

Offline OCR for desktop.

Recognize text from existing images with the CLI, or capture a screen region with the desktop app on Linux. Results are copied directly to the clipboard.

## Installation

### CLI

Debian/Ubuntu:

```bash
sudo apt install ./kocr-cli-<version>-linux-<arch>.deb
```

Fedora/RHEL:

```bash
sudo dnf install ./kocr-cli-<version>-linux-<arch>.rpm
```

Arch Linux:

```bash
paru -S kocr-bin
```

macOS:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/KercyDing/kocr/main/cli.sh)"
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/KercyDing/kocr/main/cli.ps1 -OutFile cli.ps1
.\cli.ps1
```

Use `.\cli.ps1 uninstall` to remove it.

The CLI package installs `kocr` only. It does not install the daemon, GUI, or desktop packages. Install a model with `kocr install 1`. No ONNX Runtime required.

### GUI

Debian/Ubuntu:

```bash
sudo apt install ./kocr-gui-qt-<version>-linux-<arch>.deb
```

Fedora/RHEL:

```bash
sudo dnf install ./kocr-gui-qt-<version>-linux-<arch>.rpm
```

Arch Linux:

```bash
paru -S kocr-qt-bin
```

Use `kocr-gui-gtk` / `kocr-gtk-bin` instead on GTK-based desktops. The GUI package installs `kocr-gui`, `kocr-daemon`, and a KOCR Settings menu entry, without the CLI. Open KOCR Settings to install a model and enable shortcuts.

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
kocr-gui                       # Manage models, shortcuts, and the daemon
```

`--path` (`-p`) sets the parent directory; kocr appends the model name and stores the absolute path in `config.toml`. The default is `$XDG_DATA_HOME/kocr/models`.

Models are INT8-quantized RTen packages, available in small, medium, and tiny tiers.

## Keyboard Shortcuts

Enable shortcuts in KOCR Settings. The daemon provides three default shortcuts:

| Shortcut | Action |
|----------|--------|
| `Alt+1`  | Capture and copy PNG |
| `Alt+2`  | Capture, OCR, and copy text |
| `Alt+3`  | Capture, OCR, merge into one line, and copy text |

Change shortcuts with `kocr-gui`. The daemon reloads the configuration automatically on save.

## Configuration

`kocr list` prints the configuration path. Edit it with your own editor; there is no `kocr config` command. The GUI writes the same file.

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
