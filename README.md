# kocr

Offline OCR for images.

## Build

```bash
zig build
```

Run:

```bash
zig build run -- image images/1.png
```

`kocr image images/1.png` detects and recognizes all text. Use `--line` for a single cropped text line, or `--detect` to print detected boxes.

Install a model package:

```bash
kocr list
kocr install tiny
kocr install small --force
kocr uninstall small
kocr use small
```

`kocr list` shows every profile with its status and path. `kocr install` selects the profile it installs. `kocr use` persists the selected model in `~/.config/kocr/config.json` (or `$XDG_CONFIG_HOME/kocr/config.json`) on Linux and in `~/Library/Preferences/kocr/config.json` on macOS. `kocr image` uses it unless `--profile` or `--model_dir` is given, and prints the available installs when no model is installed.

## GUI

The GUI is shared across Linux, Windows, and macOS and drawn with [nanoui](https://github.com/justrach/nanoui): D3D11 on Windows, Metal on macOS, GTK on Linux.

```bash
zig build gui
./zig-out/bin/kocr-gui
```

Or:

```bash
zig build run-gui
```

On Linux the GUI ships as `kocr-<version>-linux-<arch>.tar.gz`: extract it and run `./setup.sh` to install the binary, desktop entry, and icons into `~/.local` (`PREFIX=/usr ./setup.sh` for a system install). The CLI ships separately as `kocr-cli-<version>-linux-<arch>.tar.gz`.

The GUI provides one-shot capture actions, model management, text/image history, and a Settings dialog for shortcuts and daemon autostart. Shortcuts are executed by `kocr-gui --daemon` (platform code in `src/gui/daemon/`), so the GUI does not need to stay open.

Saving settings starts the daemon immediately; enabling autostart writes `~/.config/autostart/kocr-daemon.desktop` on Linux and the system login item (SMAppService) on macOS. History is stored in `kocr/history.sqlite3`, with image copies in `kocr/history/`.

## Using Only

If [Only](https://github.com/onlyjs/only) is installed, the same workflow is available through the project `Onlyfile`:

```bash
only cli build
only cli run image images/1.png
only gui build
only gui run
only package
only clean
```
