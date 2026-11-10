# kocr

Offline OCR for images and screen captures.

No account, no server, no uploads.

The GUI is the way in; the CLI exists for scripts and agents.

<img width="600" alt="image" src="https://github.com/user-attachments/assets/f823db07-39fd-419c-b5b4-63c54bebf2e6" />

## What you get

- **Local recognition.** [PP-OCRv6](https://www.paddleocr.ai/main/en/version3.x/pipeline_usage/OCR.html) model packs run on [ncnn.zig](https://github.com/kercyding/ncnn.zig); images never leave the machine.
- **A small native GUI.** Capture a region, copy the image, or pull out its text. Drawn with [nanoui](https://github.com/justrach/nanoui).
- **History that persists.** Texts and captures are kept in SQLite, with image copies beside it.
- **Shortcuts when you want them.** Served by `kocr-gui --daemon`.
- **A CLI for automation.** One image in, text out — for scripts, pipelines, and agents, not the everyday path.

## Install

Everything is on [Releases](https://github.com/KercyDing/kocr/releases).

### GUI

**Linux**

```sh
tar -xzf kocr-<version>-linux-amd64.tar.gz
cd kocr-<version>
./setup.sh
```

On Arch:

```sh
paru -S kocr-gui-bin
```

**Linux capture is KDE-only.** It shells out to `spectacle --region`, so GNOME and other desktops are not supported for capturing yet (recognition and the CLI are desktop-independent).

**macOS** — open the `.dmg`, drag `kocr.app` to Applications, and allow it in **System Settings → Privacy & Security**: the app is unsigned.

**Windows** — run the `setup.exe` installer.

### CLI

The CLI on its own, for automation:

- Linux: `kocr-cli-<version>-linux-<arch>.tar.gz`
- macOS: `kocr-cli-<version>-macos-<arch>.tar.gz`
- Windows: `kocr-cli-<version>-windows-<arch>.zip`

On Arch, `paru -S kocr-bin` installs the CLI alone.

## GUI

```sh
zig build run-gui
```

Four actions, from the tray menu or a shortcut (the window is history and settings):

| Action | What it does |
| --- | --- |
| Copy image | capture a region, copy the PNG |
| Save image | capture, choose a path, save, copy |
| Extract text | capture, recognize, copy the text |
| One line | same, with the text joined into a single line |

History keeps every text and capture; hover an image row for a preview. Settings covers the model, shortcuts, the theme, login autostart, and the tray icon. The theme is `auto` (follow the system), `light`, or `dark`.

On Linux the shortcuts come from `kocr-gui --daemon`, which the app starts with its window: closing the window does not cost you the hotkeys. The window keeps the settings, the about box, and the history.

## CLI

For scripts and agents; the GUI covers everyday use.

```sh
kocr install tiny            # download a model pack: tiny, small or medium
kocr use tiny                # make it the default
kocr list                    # what is installed, and where

kocr image images/1.png      # print the recognized text
kocr image shot.png --line   # one cropped line of text
kocr image shot.png --detect # print the detected boxes too
```

`kocr list` prints each profile's status and path. `kocr image` uses the selected profile unless `--profile` or `--model_dir` says otherwise. Model packs download on demand and are checked against their SHA-256.

## Build from source

Needs Zig 0.17.1; the GUI needs GTK on Linux at run time.

```sh
zig build            # both
zig build gui        # GUI
zig build cli        # CLI
zig build test       # tests
zig build run-cli -- image images/1.png
```

## Using Only

With [Only](https://github.com/KercyDing/only) installed, the project `Onlyfile` mirrors the common workflows:

```bash
only build               # build the CLI and the GUI
only build-release       # same, optimized and stripped
only gui run
only cli build
only cli install         # install the CLI
only package             # build release and package this platform
```

## License

[MIT](LICENSE)
