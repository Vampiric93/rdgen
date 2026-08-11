#!/usr/bin/env python3
import argparse
from pathlib import Path


COMPANY_NAMES = (
    "Purslane Tech Pte. Ltd.",
    "Purslane Ltd.",
    "Purslane Ltd",
    "PURSLANE",
)


def replace_in_file(path: Path, company: str, quote: str) -> bool:
    if not path.is_file():
        return False

    text = path.read_text(encoding="utf-8")
    if quote == "double":
        replacement = company.replace("\\", "\\\\").replace('"', '\\"')
    elif quote == "windows_rc":
        # Resource Compiler strings escape literal quotes by doubling them.
        replacement = company.replace('"', '""')
    elif quote == "single":
        replacement = company.replace("\\", "\\\\").replace("'", "\\'")
    else:
        replacement = company

    updated = text
    for old_name in COMPANY_NAMES:
        updated = updated.replace(old_name, replacement)
    updated = updated.replace(
        r'r"Purslane(?: Tech Pte\.)? Ltd"',
        f'"{replacement}"',
    )

    if updated != text:
        path.write_text(updated, encoding="utf-8", newline="")
        return True
    return False


def update_powered_by(source_root: Path, company: str) -> None:
    language_dir = source_root / "src" / "lang"
    escaped_company = company.replace("\\", "\\\\").replace('"', '\\"')

    for path in language_dir.glob("*.rs"):
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        changed = False
        for index, line in enumerate(lines):
            if '("powered_by_me",' in line and "RustDesk" in line:
                lines[index] = line.replace("RustDesk", escaped_company)
                changed = True
        if path.name == "ru.rs":
            for index, line in enumerate(lines):
                if '("powered_by_me",' in line:
                    indentation = line[: len(line) - len(line.lstrip())]
                    newline = "\r\n" if line.endswith("\r\n") else "\n"
                    lines[index] = (
                        f'{indentation}("powered_by_me", '
                        f'"IT решения для бизнеса | {escaped_company}"),{newline}'
                    )
                    changed = True
                    break
            else:
                raise RuntimeError("powered_by_me was not found in src/lang/ru.rs")
        if changed:
            path.write_text("".join(lines), encoding="utf-8", newline="")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--company", required=True)
    args = parser.parse_args()

    root = args.source_root.resolve()
    company = args.company.strip()
    if not company:
        raise ValueError("Company name is empty")

    double_quoted_files = (
        "Cargo.toml",
        "libs/portable/Cargo.toml",
        "src/main.rs",
        "res/msi/preprocess.py",
    )
    single_quoted_files = (
        "flutter/lib/desktop/pages/desktop_setting_page.dart",
    )
    plain_text_files = (
        "flutter/macos/Runner/Configs/AppInfo.xcconfig",
        "res/msi/Package/License.rtf",
        "src/ui/index.tis",
    )

    changed_files = []
    for relative_path in double_quoted_files:
        path = root / relative_path
        if replace_in_file(path, company, "double"):
            changed_files.append(relative_path)
    runner_rc = root / "flutter/windows/runner/Runner.rc"
    if replace_in_file(runner_rc, company, "windows_rc"):
        changed_files.append("flutter/windows/runner/Runner.rc")
    for relative_path in single_quoted_files:
        path = root / relative_path
        if replace_in_file(path, company, "single"):
            changed_files.append(relative_path)
    for relative_path in plain_text_files:
        path = root / relative_path
        if replace_in_file(path, company, "plain"):
            changed_files.append(relative_path)

    update_powered_by(root, company)
    print(f"Applied safe company branding to {len(changed_files)} source files and translations")


if __name__ == "__main__":
    main()
