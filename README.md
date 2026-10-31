# KOCR

Offline OCR for desktop and CLI. Capture a screen region or recognize an existing image; text and PNGs are copied to the clipboard. No ONNX Runtime required.

## Install

Linux packages are published as `.deb`, `.rpm`, and AUR builds. Replace `<version>` and `<arch>` with the downloaded release values.

```bash
# Debian / Ubuntu
sudo apt install ./kocr-cli-<version>-linux-<arch>.deb   # CLI
sudo apt install ./kocr-gui-<version>-linux-<arch>.deb   # GUI

# Fedora / RHEL
sudo dnf install ./kocr-cli-<version>-linux-<arch>.rpm   # CLI
sudo dnf install ./kocr-gui-<version>-linux-<arch>.rpm   # GUI

# Arch Linux
paru -S kocr-bin        # CLI
paru -S kocr-gui-bin    # GUI
```

macOS:

```bash
# CLI
bash -c "$(curl -fsSL https://raw.githubusercontent.com/KercyDing/kocr/main/cli.sh)"

# GUI: download kocr-gui-<version>-<arch>-apple-darwin.zip and open kocr.app
```

Windows:

```powershell
# CLI
irm https://raw.githubusercontent.com/KercyDing/kocr/main/cli.ps1 -OutFile cli.ps1
.\cli.ps1

# GUI: download kocr-gui-<version>-<arch>-pc-windows-msvc.zip and run kocr-gui.exe
```

## Use

GUI:

- **Copy** captures a region and copies the PNG.
- **Save** captures a region, asks for a path, saves the PNG, and copies it.
- **Extract** captures a region, runs OCR, and copies the text.
- **Extract as one line** merges OCR text into one line before copying.

CLI:

```bash
kocr image test.png          # Print recognized text to stdout
kocr list                    # Show models and config path
kocr install 1               # Install a model by ID
kocr install 1 -p <DIR>      # Choose the model parent directory
kocr use 1                   # Select the active model
kocr uninstall 1             # Remove a model
```

The GUI also installs and selects models. Models are INT8-quantized RTen packages.

## Shortcuts And Config

Open **Shortcuts** in the GUI and assign keys. Shortcuts are unset by default; Extract actions require an installed model.

| Action | Default |
|--------|---------|
| Copy | unset |
| Save | unset |
| Extract | unset |
| Extract as one line | unset |

`kocr list` prints the config path. Edit `config.toml` directly:

```toml
[shortcut]
copy = "Alt+1"
save = "Alt+2"
ocr = "Alt+3"
oneline = "Alt+4"

[models]
select = "ppocrv6-small-int8-r1"
```

Supported modifiers: `Mod`, `Super`, `Ctrl`, `Alt`, `Shift`. Set a shortcut to an empty string to disable it.

## License

[Apache License 2.0](LICENSE)

Third-party notices: [NOTICE](NOTICE)  
OCR models are based on PaddleOCR: [LICENSE-PaddleOCR](LICENSE-PaddleOCR).
