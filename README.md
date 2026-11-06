# kocr

Offline OCR for images.

## Build

```bash
zig build
```

Run:

```bash
zig build run -- image image.png
```

`kocr image image.png` detects and recognizes all text. Use `--line` for a single cropped text line, or `--detect` to print detected boxes.

Install a model package:

```bash
kocr list
kocr install tiny
kocr install small --force
kocr uninstall small
kocr use small
```

`kocr use` persists the selected model in `~/.config/kocr/config.json` (or `$XDG_CONFIG_HOME/kocr/config.json`). `kocr image` uses it unless `--profile` or `--model_dir` is given.

## GUI

Linux uses the native Qt6 Widgets frontend from `rcalixte/libqt6zig`. Qt 6.8+ development files are required.

```bash
zig build gui
./zig-out/bin/kocr-gui
```

Or:

```bash
zig build run-gui
```

The GUI provides one-shot capture actions, model management, text/image history, and a Settings dialog for shortcuts and daemon autostart. Shortcuts are executed by the standalone `kocr daemon` process, so the GUI does not need to stay open. Saving settings starts the daemon immediately; enabling autostart writes `~/.config/autostart/kocr-daemon.desktop`. History is stored in `kocr/history.sqlite3`, with image copies in `kocr/history/`.

Windows (`zigwin32`) and macOS (`zig-objc`) entry points are wired into the build but currently stop with an explicit "not implemented" compile error.

## Using Only

If [Only](https://github.com/onlyjs/only) is installed, the same workflow is available through the project `Onlyfile`:

```bash
only cli build
only cli run image image.png
only gui build
only gui run
only gui install
only gui uninstall
only clean
```
