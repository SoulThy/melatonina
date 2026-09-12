<h1 align="center">
  <img src="logo/gecko_logo_colored.svg" width="140" align="absmiddle" alt="melatonina logo"> melatonina
</h1>

<p align="center">
  <strong>A simple blue light filter for Wayland, written entirely in Zig.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-0.17-F7A41D.svg?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.17">
  <img src="https://img.shields.io/badge/Wayland-wlroots-blue?style=flat-square" alt="Wayland">
</p>

---

## What is this?

`melatonina` adjusts your screen's color temperature (like redshift or gammastep), but with zero external dependencies thus no libwayland and no libc bindings.

It's small and simple on purpose. I wanted my screen warmer at night and nothing more.

## Requirements

- Zig **0.17**
- A Wayland compositor that supports `wlr-gamma-control-unstable-v1` (most wlroots-based compositors do)

## Build

```sh
zig build
```

If you want the binary somewhere specific:

```sh
zig build --prefix <path>
```

## Usage

```
Usage: ./melatonina [options]

Options:
  -k [k]elvin_temperature

Example: ./melatonina -k 4500
```

1000K - `#ff3300`<br>
2500K - `#ff6600`<br>
3500K - `#ff9933`<br>
4500K - `#ffcc66`<br>
5500K - `#ffffff`
