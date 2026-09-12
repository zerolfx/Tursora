#!/usr/bin/env python3
"""Build the dependency-free product page from canonical repository assets."""

from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
import sys
from urllib.parse import unquote, urlsplit

SITE = Path(__file__).resolve().parent
ROOT = SITE.parent
DIST = SITE / "dist"
ASSETS = {
    "AppIcon.png": ROOT / "app/Resources/AppIcon.png",
    "path-navigation.png": ROOT / "docs/images/features/path-navigation.png",
    "split-panes.png": ROOT / "docs/images/features/split-panes.png",
    "zip-browsing.png": ROOT / "docs/images/features/zip-browsing.png",
}


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.references = []
        self.errors = []
        self.feature_count = 0

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                self.errors.append(f"Duplicate ID: {attrs['id']}")
            self.ids.add(attrs["id"])
        if "data-panel" in attrs:
            self.feature_count += 1
        if tag == "img" and "alt" not in attrs:
            self.errors.append("Image is missing alt text")
        for key in ("href", "src"):
            if attrs.get(key):
                self.references.append((tag, attrs[key]))


def validate():
    page = Page()
    page.feed((DIST / "index.html").read_text(encoding="utf-8"))
    errors = page.errors
    if page.feature_count != 3:
        errors.append(f"Expected three workflow panels, found {page.feature_count}")
    css = (DIST / "styles.css").read_text(encoding="utf-8")
    references = page.references + [("style", ref.strip("\"' ")) for ref in re.findall(r"url\(([^)]+)\)", css)]
    for tag, reference in references:
        parsed = urlsplit(reference)
        if parsed.scheme or parsed.netloc:
            if tag != "a" or parsed.scheme != "https" or parsed.netloc != "github.com":
                errors.append(f"Unexpected external dependency or link: {reference}")
            continue
        if parsed.path.startswith("/"):
            errors.append(f"Absolute path breaks subpath hosting: {reference}")
            continue
        target = (DIST / unquote(parsed.path or "index.html")).resolve()
        if not target.is_relative_to(DIST.resolve()) or not target.is_file():
            errors.append(f"Missing or escaping local reference: {reference}")
        if parsed.fragment and (not parsed.path or parsed.path == "index.html") and unquote(parsed.fragment) not in page.ids:
            errors.append(f"Missing fragment target: {reference}")
    if errors:
        raise ValueError("\n".join(errors))
    return len(references)


def main():
    html = (SITE / "index.html").read_text(encoding="utf-8")
    assets = dict(ASSETS)
    for source in assets.values():
        if not source.is_file():
            raise FileNotFoundError(f"Missing canonical asset: {source.relative_to(ROOT)}")
    if DIST.is_symlink():
        raise ValueError("Refusing to replace a symlink at site/dist")
    if DIST.exists():
        shutil.rmtree(DIST)
    (DIST / "assets").mkdir(parents=True)
    (DIST / "index.html").write_text(html, encoding="utf-8")
    for filename in ("styles.css", "main.js"):
        shutil.copy2(SITE / filename, DIST / filename)
    for filename, source in assets.items():
        shutil.copy2(source, DIST / "assets" / filename)
    reference_count = validate()
    size = sum(path.stat().st_size for path in DIST.rglob("*") if path.is_file())
    print(f"Built site/dist: {len(assets)} canonical assets, {reference_count} references checked, {size / 1024:.0f} KiB.")
    print("Preview: python3 -m http.server 8080 --directory site/dist")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        sys.exit(1)
