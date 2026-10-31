# KDEOCR

Offline OCR for KDE Plasma 6 on Wayland.

Recognize text from existing images or capture a screen region with Spectacle. Results are copied directly to the Wayland clipboard.

## Installation

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/KercyDing/kdeocr/main/script.sh)"
```

The installer downloads `kocr`, installs any missing runtime dependencies, and then installs the selected OCR model. OCR runs on the pure-Rust RTen engine, so ONNX Runtime is not required.

Supported package-manager families are Arch/CachyOS, Debian/Ubuntu, and Fedora/RHEL.

## Usage

### Screen Capture

```bash
kocr capture          # Capture region, copy PNG to clipboard
kocr capture -o       # Capture region, run OCR, copy text to clipboard
```

### Existing Image

```bash
kocr image test.png   # Recognize text and print to stdout
```

### OCR Models

```bash
kocr list             # List available models
kocr install 1        # Install by ID or name
kocr install 1 -p ~/<path>/ppocrv6-small-r1
kocr use 1            # Set active model
kocr uninstall 1      # Remove a model
kocr config           # Open configuration in your default editor
```

`--path` (`-p`) sets the complete model directory and stores its absolute path in `config.toml`.

Models are INT8-quantized RTen packages, available in small, medium, and tiny tiers.

## Keyboard Shortcuts

The installer registers a systemd user service with three default shortcuts:

| Shortcut | Action |
|----------|--------|
| `Alt+1`  | Capture and copy PNG |
| `Alt+2`  | Capture, OCR, and copy text |
| `Alt+3`  | Capture, OCR, merge into one line, and copy text |

Change shortcuts with `kocr config`. The daemon reloads the configuration automatically on save.

## Configuration

`kocr config` opens `~/.config/kdeocr/config.toml` in the editor specified by `VISUAL`, `EDITOR`, or the desktop default.

Example:

```toml
[shortcut]
copy = "Alt+1"
ocr  = "Alt+2"
oneline = "Alt+3"

[models]
select = "ppocrv6-small-r1"

[models.ppocrv6-small-r1]
path = "/home/user/.local/share/kdeocr/models/ppocrv6-small-r1"
```

Supported modifiers: `Mod`, `Ctrl`, `Alt`, `Shift`.  
Key examples: `A-Z`, `0-9`, `F1-F35`, `Escape`, `Space`, `Slash`.  
Set a shortcut to an empty string to disable it.

## License

[Apache License 2.0](LICENSE)

Third-party notices: [NOTICE](NOTICE)
