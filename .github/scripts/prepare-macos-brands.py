#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(*args):
    subprocess.run(args, check=True)


def replace_icon(bundle: Path, source: Path, work: Path) -> None:
    assets = bundle / "Contents/Frameworks/App.framework/Versions/Current/Resources/flutter_assets/assets"
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, assets / "icon.png")
    pbm = work / "icon.pbm"
    run("magick", str(source), str(pbm))
    run("potrace", "--svg", "-o", str(assets / "icon.svg"), str(pbm))

    iconset = work / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    sizes = ((16, "16x16"), (32, "16x16@2x"), (32, "32x32"),
             (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
             (256, "256x256"), (512, "256x256@2x"), (512, "512x512"),
             (1024, "512x512@2x"))
    for size, name in sizes:
        run("magick", str(source), "-resize", f"{size}x{size}", str(iconset / f"icon_{name}.png"))
    icns = work / "AppIcon.icns"
    run("iconutil", "-c", "icns", str(iconset), "-o", str(icns))
    info_plist = bundle / "Contents/Info.plist"
    with info_plist.open("rb") as source_file:
        info = plistlib.load(source_file)
    icon_name = info.get("CFBundleIconFile", "AppIcon")
    if not icon_name.endswith(".icns"):
        icon_name += ".icns"
    destination = bundle / "Contents/Resources" / icon_name
    if not destination.is_file():
        raise RuntimeError(f"App icon resource not found: {destination}")
    shutil.copy2(icns, destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    brands = json.loads(os.environ.get("brands_json") or "[]")
    if not brands:
        brands = [{"filename": os.environ.get("filename", "rustdesk"), "icon": "", "logo": ""}]
    assets_dir = Path(os.environ["RDGEN_ASSETS_DIR"])
    root = Path(os.environ["RUNNER_TEMP"]) / "rdgen-macos-brands"
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    prepared = []

    for index, brand in enumerate(brands):
        brand_dir = root / str(index)
        bundle = brand_dir / f"{args.app_name}.app"
        shutil.copytree(args.bundle, bundle, symlinks=True)
        if index and brand.get("logo"):
            logo = assets_dir / brand["logo"]
            destination = bundle / "Contents/Frameworks/App.framework/Versions/Current/Resources/flutter_assets/assets/logo.png"
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(logo, destination)
        if index and brand.get("icon"):
            replace_icon(bundle, assets_dir / brand["icon"], brand_dir)
        prepared.append({
            "bundle": str(bundle),
            "filename": brand["filename"],
            "dmg": str(args.workspace / f"{brand['filename']}-{args.arch}.dmg"),
        })

    args.output.write_text(json.dumps(prepared), encoding="utf-8")
    print(f"Prepared {len(prepared)} branded macOS app bundle(s).")


if __name__ == "__main__":
    main()
