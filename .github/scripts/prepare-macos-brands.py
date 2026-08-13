#!/usr/bin/env python3
import argparse
import base64
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


def install_custom_config(bundle: Path, encoded_config: str) -> None:
    if not encoded_config:
        return
    try:
        decoded = base64.b64decode(encoded_config, validate=True)
        parsed = json.loads(decoded)
    except (ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("Invalid macOS custom client configuration") from error
    if not isinstance(parsed, dict):
        raise RuntimeError("macOS custom client configuration must be a JSON object")

    # allowCustom.py changes RustDesk's loader to read custom_.txt and accept
    # RDGen's unsigned base64 JSON. The file must be inside the app bundle on
    # macOS; unlike Windows, there is no adjacent runtime directory to copy it from.
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "custom_.txt").write_text(encoded_config, encoding="ascii")


DIRECTION_SUFFIXES = {
    "incoming": "incoming",
    "outgoing": "outgoing",
    "both": "full",
}


def selected_direction_configs(environ=os.environ):
    requested = [value.strip() for value in environ.get("directions", "both").split(",")]
    requested = list(dict.fromkeys(value for value in requested if value))
    if not requested:
        requested = ["both"]

    configs = []
    for direction in requested:
        if direction not in DIRECTION_SUFFIXES:
            raise RuntimeError(f"Unsupported macOS connection type: {direction}")
        encoded_config = environ.get(f"custom_{direction}", "").strip()
        if not encoded_config:
            raise RuntimeError(f"Missing macOS custom configuration for {direction}")
        configs.append((direction, DIRECTION_SUFFIXES[direction], encoded_config))
    return configs


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
    direction_configs = selected_direction_configs()
    root = Path(os.environ["RUNNER_TEMP"]) / "rdgen-macos-brands"
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    prepared = []

    for index, brand in enumerate(brands):
        for direction, direction_suffix, custom_config in direction_configs:
            brand_dir = root / str(index) / direction
            bundle = brand_dir / f"{args.app_name}.app"
            shutil.copytree(args.bundle, bundle, symlinks=True)
            install_custom_config(bundle, custom_config)
            if index and brand.get("logo"):
                logo = assets_dir / brand["logo"]
                destination = bundle / "Contents/Frameworks/App.framework/Versions/Current/Resources/flutter_assets/assets/logo.png"
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(logo, destination)
            if index and brand.get("icon"):
                replace_icon(bundle, assets_dir / brand["icon"], brand_dir)
            output_filename = f"{brand['filename']}_{direction_suffix}"
            prepared.append({
                "bundle": str(bundle),
                "filename": output_filename,
                "direction": direction,
                "dmg": str(args.workspace / f"{output_filename}-{args.arch}.dmg"),
            })

    args.output.write_text(json.dumps(prepared), encoding="utf-8")
    print(f"Prepared {len(prepared)} branded macOS app bundle(s).")


if __name__ == "__main__":
    main()
