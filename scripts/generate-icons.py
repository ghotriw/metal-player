#!/usr/bin/env python3
"""
Logo & App Icon generation pipeline for Nits.

Features:
- Renders SVGs from template.svg + themes.json
- Generates macOS AppIcon.icns via native macOS AppKit and iconutil
- Supports theme selection
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
LOGO_DIR = ROOT_DIR / "logo"
TEMPLATE_PATH = LOGO_DIR / "template.svg"
THEMES_PATH = LOGO_DIR / "themes.json"
DIST_DIR = ROOT_DIR / "build" / "logo"
APP_RESOURCES_DIR = ROOT_DIR / "Sources" / "NitsApp" / "Resources"
DEFAULT_ICNS_PATH = APP_RESOURCES_DIR / "AppIcon.icns"

ICONSET_SPECS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def load_themes():
    with open(THEMES_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def load_template():
    with open(TEMPLATE_PATH, "r", encoding="utf-8") as f:
        return f.read()


def build_stops(stops_data):
    lines = []
    for s in stops_data:
        offset_attr = f' offset="{s["offset"]}"' if s.get("offset") and s["offset"] != "0" else ""
        lines.append(f'<stop{offset_attr} stop-color="{s["color"]}"/>')
    return "\n".join(lines)


def render_svg(theme_name, theme_data, template_str):
    p0 = build_stops(theme_data["gradients"]["paint0"])
    p1 = build_stops(theme_data["gradients"]["paint1"])
    p2 = build_stops(theme_data["gradients"]["paint2"])

    content = template_str.replace("{{SHADOW_MATRIX}}", theme_data["shadow_matrix"])
    content = content.replace("{{PAINT0_STOPS}}", p0)
    content = content.replace("{{PAINT1_STOPS}}", p1)
    content = content.replace("{{PAINT2_STOPS}}", p2)
    return content


def generate_svgs(themes, template_str, selected_theme=None):
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    generated = {}

    for theme_name, theme_data in themes.items():
        if selected_theme and theme_name != selected_theme:
            continue
        out_path = DIST_DIR / f"logo-{theme_name}.svg"
        svg_content = render_svg(theme_name, theme_data, template_str)
        out_path.write_text(svg_content, encoding="utf-8")
        generated[theme_name] = out_path
        print(f"✓ Rendered SVG: {out_path.relative_to(ROOT_DIR)} ({len(svg_content)} bytes)")

    return generated


def generate_icns(svg_path, output_icns_path):
    iconutil = shutil.which("iconutil")
    swift = shutil.which("swift")

    if not iconutil or not swift:
        print("Error: 'iconutil' or 'swift' not found. Available on macOS.", file=sys.stderr)
        return False

    temp_iconset = DIST_DIR / "AppIcon.iconset"
    if temp_iconset.exists():
        shutil.rmtree(temp_iconset)
    temp_iconset.mkdir(parents=True, exist_ok=True)

    print(f"Generating iconset from {svg_path.name} via macOS AppKit...")
    try:
        # We rasterize via native macOS AppKit to preserve all color gradients and SVG masks perfectly.
        escaped_svg_path = json.dumps(str(svg_path.resolve()))
        escaped_iconset_dir = json.dumps(str(temp_iconset.resolve()))
        specs_literal = ", ".join(f'("{fn}", {sz})' for fn, sz in ICONSET_SPECS)

        swift_script = f"""
import AppKit

let svgURL = URL(fileURLWithPath: {escaped_svg_path})
guard let image = NSImage(contentsOf: svgURL) else {{
    exit(1)
}}

let specs: [(String, Int)] = [
    {specs_literal}
]

let iconsetDir = URL(fileURLWithPath: {escaped_iconset_dir})

for (filename, size) in specs {{
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = ctx

    let s = CGFloat(size)

    // Clear background
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: s, height: s).fill()

    // 1. Apple macOS Squircle Tile (continuous rounded rectangle)
    let tileScale: CGFloat = 0.86
    let tileSize = s * tileScale
    let tileOrigin = (s - tileSize) / 2
    let tileRect = NSRect(x: tileOrigin, y: tileOrigin, width: tileSize, height: tileSize)
    let cornerRadius = tileSize * 0.225
    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Drop shadow under tile
    let tileShadow = NSShadow()
    tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    tileShadow.shadowOffset = NSSize(width: 0, height: -tileSize * 0.035)
    tileShadow.shadowBlurRadius = tileSize * 0.07

    NSGraphicsContext.saveGraphicsState()
    tileShadow.set()
    NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1.0).set()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Deeper dark gradient inside tile
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let tileGradient = NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
    )
    tileGradient?.draw(in: tileRect, angle: 90)

    // Subtle inner highlight border
    let borderPath = NSBezierPath(roundedRect: tileRect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
    borderPath.lineWidth = max(1.0, tileSize * 0.008)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    borderPath.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 2. Draw Logo Symbol inside the tile (occupying ~74% of the tile - tighter margins)
    let logoScale: CGFloat = 0.74
    let usableLogoSize = tileSize * logoScale

    let aspect = image.size.width / image.size.height
    var dw = usableLogoSize
    var dh = usableLogoSize / aspect
    if dh > usableLogoSize {{
        dh = usableLogoSize
        dw = usableLogoSize * aspect
    }}
    // Visual optical centering: play triangle visually leans left, offset slightly right
    let opticalXOffset = dw * 0.04
    let x = (s - dw) / 2 + opticalXOffset
    let y = (s - dh) / 2

    image.draw(in: NSRect(x: x, y: y, width: dw, height: dh))
    NSGraphicsContext.restoreGraphicsState()

    let targetRep = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
    guard let pngData = targetRep.representation(using: .png, properties: [:]) else {{
        exit(1)
    }}

    let outURL = iconsetDir.appendingPathComponent(filename)
    try pngData.write(to: outURL)
}}
"""
        subprocess.run([swift, "-e", swift_script], check=True)

        output_icns_path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [iconutil, "-c", "icns", str(temp_iconset), "-o", str(output_icns_path)],
            check=True
        )
        print(f"✓ Created ICNS: {output_icns_path.relative_to(ROOT_DIR)} ({output_icns_path.stat().st_size // 1024} KB)")
        return True
    finally:
        if temp_iconset.exists():
            shutil.rmtree(temp_iconset)


def main():
    parser = argparse.ArgumentParser(description="Logo & AppIcon build pipeline.")
    parser.add_argument(
        "--theme",
        choices=["emerald", "coral-pink", "monochrome", "monterey", "twilight"],
        default="monterey",
        help="Theme to generate (default: monterey)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Generate SVG files for all themes defined in themes.json",
    )
    parser.add_argument(
        "--svg-only",
        action="store_true",
        help="Only render SVG file(s), skip AppIcon.icns generation",
    )
    parser.add_argument(
        "--output-icns",
        default=str(DEFAULT_ICNS_PATH),
        help="Custom output path for .icns",
    )

    args = parser.parse_args()

    themes = load_themes()
    template_str = load_template()

    # Determine which themes to render
    target_theme = None if args.all else args.theme
    generated_svgs = generate_svgs(themes, template_str, selected_theme=target_theme)

    if not args.svg_only:
        # Generate ICNS for the requested theme
        icns_theme = args.theme
        if icns_theme not in generated_svgs:
            out_path = DIST_DIR / f"logo-{icns_theme}.svg"
            out_path.write_text(render_svg(icns_theme, themes[icns_theme], template_str), encoding="utf-8")
            generated_svgs[icns_theme] = out_path

        generate_icns(generated_svgs[icns_theme], Path(args.output_icns))


if __name__ == "__main__":
    main()
