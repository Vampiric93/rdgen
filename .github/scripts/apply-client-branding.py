#!/usr/bin/env python3
import argparse
import html
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
    elif quote == "html":
        replacement = html.escape(company, quote=True)
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


def enable_runtime_brand_assets(source_root: Path) -> None:
    path = source_root / "src" / "ui.rs"
    text = path.read_text(encoding="utf-8")
    old_loader = """pub fn get_icon() -> String {
    #[cfg(target_os = "windows")]
    if let Ok(executable) = std::env::current_exe() {
        if let Some(directory) = executable.parent() {
            let icon = directory.join("icon.png");
            if icon.is_file() {
                return format!("file:///{}", icon.to_string_lossy().replace('\\\\', "/"));
            }
        }
    }
"""
    loader = """fn runtime_png_data_uri(filename: &str) -> Option<String> {
    let executable = std::env::current_exe().ok()?;
    let bytes = std::fs::read(executable.parent()?.join(filename)).ok()?;
    Some(format!("data:image/png;base64,{}", crate::encode64(bytes)))
}

pub fn get_logo() -> String {
    runtime_png_data_uri("logo.png").unwrap_or_default()
}

pub fn get_icon() -> String {
    #[cfg(target_os = "windows")]
    if let Some(icon) = runtime_png_data_uri("icon.png") {
        return icon;
    }
"""
    marker = "pub fn get_icon() -> String {\n"
    if old_loader in text:
        text = text.replace(old_loader, loader, 1)
    elif "fn runtime_png_data_uri(filename: &str)" not in text:
        if marker not in text:
            raise RuntimeError("get_icon was not found in src/ui.rs")
        text = text.replace(marker, loader, 1)

    implementation = """    fn get_icon(&mut self) -> String {
        get_icon()
    }
"""
    if "fn get_logo(&mut self)" not in text:
        if implementation not in text:
            raise RuntimeError("UI get_icon implementation was not found")
        text = text.replace(
            implementation,
            implementation + "\n    fn get_logo(&mut self) -> String {\n        get_logo()\n    }\n",
            1,
        )
    if "        fn get_logo();" not in text:
        text = text.replace("        fn get_icon();\n", "        fn get_icon();\n        fn get_logo();\n", 1)
    path.write_text(text, encoding="utf-8", newline="")

    index_path = source_root / "src" / "ui" / "index.tis"
    index = index_path.read_text(encoding="utf-8")
    if "const custom_logo = handler.get_logo();" not in index:
        index = index.replace(
            "const is_custom_client = handler.is_custom_client();\n",
            "const is_custom_client = handler.is_custom_client();\nconst custom_logo = handler.get_logo();\n",
            1,
        )
    logo_marker = """                    <div>
                        {is_custom_client && handler.get_builtin_option("hide-powered-by-me") != "Y" ? <div .link #powered-by style="opacity:0.5;font-size:0.8em;text-decoration:underline">{translate('powered_by_me')}</div> : ""}
"""
    if "<img .custom-logo" not in index:
        if logo_marker not in index:
            raise RuntimeError("Sciter main panel marker was not found")
        index = index.replace(
            logo_marker,
            """                    <div>
                        {custom_logo ? <img .custom-logo src={custom_logo} style="display:block;width:200px;height:60px;margin:0 auto 0.8em auto" /> : ""}
                        {is_custom_client && handler.get_builtin_option("hide-powered-by-me") != "Y" ? <div .link #powered-by style="opacity:0.5;font-size:0.8em;text-decoration:underline">{translate('powered_by_me')}</div> : ""}
""",
            1,
        )
    index = index.replace(
        "display:block;max-width:200px;max-height:60px;margin:0 auto 0.8em auto",
        "display:block;width:200px;height:60px;margin:0 auto 0.8em auto",
    )
    index_path.write_text(index, encoding="utf-8", newline="")


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
    )
    html_files = ("src/ui/index.tis",)

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
    for relative_path in html_files:
        path = root / relative_path
        if replace_in_file(path, company, "html"):
            changed_files.append(relative_path)

    update_powered_by(root, company)
    enable_runtime_brand_assets(root)
    print(f"Applied safe company branding to {len(changed_files)} source files and translations")


if __name__ == "__main__":
    main()
