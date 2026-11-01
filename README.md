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

### Shortcuts

The GUI does not register capture shortcuts on first launch. Open **Shortcuts**, click an action, and press the desired key combination to register it. Use **Unbind** to remove a shortcut later.

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

## License

[Apache License 2.0](LICENSE)

Third-party notices: [NOTICE](NOTICE)  
OCR models are based on PaddleOCR: [LICENSE-PaddleOCR](LICENSE-PaddleOCR).
