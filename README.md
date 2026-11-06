# kocr

An offline OCR tool.

## Build

Build:

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
kocr install tiny
kocr install small --force
```

## Using Only

If [Only](https://github.com/onlyjs/only) is installed, the same workflow is available through the project `Onlyfile`:

```bash
only build
only run
only clean
```
