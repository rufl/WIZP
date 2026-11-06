#!/usr/bin/env python3
"""Package the basic API smoke fixture as a minimal VSIX archive."""

from __future__ import annotations

import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "testdata" / "extensions" / "basic-api-smoke"


def main() -> int:
    package = json.loads((FIXTURE / "package.json").read_text())
    name = package["name"]
    version = package["version"]
    publisher = package.get("publisher", "wizp")
    out = FIXTURE / f"{name}-{version}.vsix"

    manifest = f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Id="{name}" Version="{version}" Publisher="{publisher}" Language="en-US" />
    <DisplayName>{package.get("displayName", name)}</DisplayName>
    <Description>WIZP VS Code API smoke fixture.</Description>
    <Tags>wizp,smoke,fixture</Tags>
    <Categories>Other</Categories>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
  </Assets>
</PackageManifest>
"""

    content_types = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json" />
  <Default Extension="js" ContentType="application/javascript" />
  <Default Extension="md" ContentType="text/markdown" />
  <Default Extension="svg" ContentType="image/svg+xml" />
  <Default Extension="vsixmanifest" ContentType="text/xml" />
</Types>
"""

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types)
        zf.writestr("extension.vsixmanifest", manifest)
        for filename in ["package.json", "extension.js", "README.md"]:
            zf.write(FIXTURE / filename, f"extension/{filename}")
        for dirname in ["syntaxes", "themes", "snippets", "media", "schemas", "debugAdapters", "icons"]:
            directory = FIXTURE / dirname
            if not directory.exists():
                continue
            for path in directory.rglob("*"):
                if path.is_file():
                    zf.write(path, f"extension/{path.relative_to(FIXTURE)}")
        language_config = FIXTURE / "language-configuration.json"
        if language_config.exists():
            zf.write(language_config, "extension/language-configuration.json")

    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
