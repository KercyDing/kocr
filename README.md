# kocr

An offline OCR tool.

## Build

Build:

```bash
zig build
```

Run:

```bash
zig build run -- image.png
```

`kocr image.png` detects and recognizes all text. Use `--line` for a single cropped text line, or `--detect` to print detected boxes.

## Using Only

If [Only](https://github.com/onlyjs/only) is installed, the same workflow is available through the project `Onlyfile`:

```bash
only build
only run
only clean
```
