"""Tray flag images: PNG via GdkPixbuf; optional Pillow emoji raster."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402


def flag_emoji_from_iso(cc: str) -> str:
    if len(cc) != 2:
        return ""
    a, b = cc[0].upper(), cc[1].upper()
    if not ("A" <= a <= "Z" and "A" <= b <= "Z"):
        return ""
    return chr(0x1F1E6 + (ord(a) - ord("A"))) + chr(0x1F1E6 + (ord(b) - ord("A")))


def pixbuf_from_png_bytes(data: bytes, width: int = 22, height: int = 18) -> GdkPixbuf.Pixbuf | None:
    if len(data) < 24:
        return None
    try:
        loader = GdkPixbuf.PixbufLoader()
        loader.write(data)
        loader.close()
        pb = loader.get_pixbuf()
        if pb is None:
            return None
        return pb.scale_simple(width, height, GdkPixbuf.InterpType.BILINEAR)
    except GLib.Error:
        return None


def write_temp_png(pb: GdkPixbuf.Pixbuf) -> str | None:
    try:
        fd, path = tempfile.mkstemp(prefix="ipchanger-flag-", suffix=".png")
        os.close(fd)
        try:
            pb.savev(path, "png", [], [])
        except GLib.Error:
            Path(path).unlink(missing_ok=True)
            return None
        return path
    except OSError:
        return None


def emoji_pixbuf(emoji: str, size: int = 64) -> GdkPixbuf.Pixbuf | None:
    try:
        from PIL import Image, ImageDraw, ImageFont  # type: ignore[import-untyped]
    except ImportError:
        return None
    text = emoji if emoji else "🌐"
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    font = None
    for path in (
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/opentype/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/noto/NotoColorEmoji.ttf",
    ):
        try:
            font = ImageFont.truetype(path, size=int(size * 0.75))
            break
        except OSError:
            continue
    if font is None:
        try:
            font = ImageFont.load_default()
        except OSError:
            return None
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = max(0, (size - tw) // 2)
    y = max(0, (size - th) // 2)
    draw.text((x, y), text, font=font, embedded_color=True)
    buf_path = write_temp_png_pil(img)
    if not buf_path:
        return None
    try:
        return GdkPixbuf.Pixbuf.new_from_file_at_size(buf_path, 22, 18)
    finally:
        Path(buf_path).unlink(missing_ok=True)


def write_temp_png_pil(img) -> str | None:  # type: ignore[no-untyped-def]
    try:
        fd, path = tempfile.mkstemp(prefix="ipchanger-emoji-", suffix=".png")
        os.close(fd)
        img.save(path, format="PNG")
        return path
    except OSError:
        return None
