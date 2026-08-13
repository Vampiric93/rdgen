#!/usr/bin/env python3
import argparse
from pathlib import Path


REPLACEMENTS = (
    ("libs/hbb_common/src/config.rs", "rs-ny.rustdesk.com", "server"),
    (
        "libs/hbb_common/src/config.rs",
        "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=",
        "key",
    ),
    ("src/common.rs", "https://admin.rustdesk.com", "api_server"),
)


def apply_custom_server(source_root: Path, server: str, key: str, api_server: str) -> None:
    values = {"server": server, "key": key, "api_server": api_server}
    for relative_path, original, value_name in REPLACEMENTS:
        path = source_root / relative_path
        text = path.read_text(encoding="utf-8")
        if original not in text:
            raise RuntimeError(f"Expected default value was not found in {relative_path}")
        path.write_text(text.replace(original, values[value_name]), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--server", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--api-server", required=True)
    args = parser.parse_args()

    apply_custom_server(
        args.source_root.resolve(),
        args.server,
        args.key,
        args.api_server,
    )
    print("Applied custom Host, Key, and API Server settings")


if __name__ == "__main__":
    main()
