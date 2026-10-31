# KOCR

Offline OCR for desktop and CLI.

## GUI

- **Linux**: install the `.deb` or `.rpm` from [Releases](https://github.com/KercyDing/kocr/releases), or `paru -S kocr-gui-bin`.
- **macOS**: open the `.dmg` from [Releases](https://github.com/KercyDing/kocr/releases).
- **Windows**: run the installer from [Releases](https://github.com/KercyDing/kocr/releases).

Capture actions:

- **Copy**: capture a region and copy the PNG.
- **Save**: capture a region, choose a path, save the PNG, and copy it.
- **Extract**: capture, run OCR, and copy the text.
- **Extract as one line**: merge OCR text into one line before copying.

Install and select OCR models from the Models page.

## CLI

- **Linux**: install the `.deb` or `.rpm` from [Releases](https://github.com/KercyDing/kocr/releases), or `paru -S kocr-bin`.
- **macOS**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/KercyDing/kocr/main/cli.sh)"
```

- **Windows**:

```powershell
irm https://raw.githubusercontent.com/KercyDing/kocr/main/cli.ps1 | iex
```

### Usage

```bash
kocr image test.png          # Print recognized text
kocr list                    # Show models and config path
kocr install 1               # Install a model
kocr use 1                   # Select a model
kocr uninstall 1             # Remove a model
```

## Shortcuts

Open **Shortcuts** in the GUI. Shortcuts are unset by default.

## Config

`kocr list` prints the config path.

```toml
[shortcut]
copy = "Alt+1"
save = "Alt+2"
ocr = "Alt+3"
oneline = "Alt+4"
```

Supported modifiers: `Mod`, `Super`, `Ctrl`, `Alt`, `Shift`. Set a shortcut to an empty string to disable it.

## License

[Apache License 2.0](LICENSE)

Third-party notices: [NOTICE](NOTICE)  
OCR models are based on PaddleOCR: [LICENSE-PaddleOCR](LICENSE-PaddleOCR).
