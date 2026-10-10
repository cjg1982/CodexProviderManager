#!/usr/bin/env python3
"""Package reviewed source files only, never personal runtime data or binaries."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parent.parent
files = [root / name for name in (
    ".gitignore", "README.md", "LICENSE", "SECURITY.md", "build.sh", "test.sh", "release.sh"
)]
for directory in ("Sources", "Tests", "Resources", "scripts", "docs", ".github"):
    files.extend(p for p in (root / directory).rglob("*") if p.is_file()
                 and p.suffix in (".swift", ".toml", ".plist", ".py", ".md", ".yml"))
output = root / "dist" / "Codex-Provider-Manager-Source.zip"
output.parent.mkdir(exist_ok=True)
with ZipFile(output, "w", ZIP_DEFLATED) as archive:
    for path in sorted(set(files)):
        archive.write(path, "CodexProviderManager/" + path.relative_to(root).as_posix())
print("Packaged source:", output.name)
