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
sys.path.insert(0, str(ROOT / "app/tools"))
from screenshot_alpha import validate as validate_screenshot_alpha

DIST = SITE / "dist"
# The published version lives in one place. Pages and the installation guide
# carry a {{VERSION}} placeholder so a release never edits prose in four files.
VERSION_FILE = ROOT / "VERSION"
SUBSTITUTED = ("index.html", "zh.html", "install.md")
PAGES = {"index.html": "en", "zh.html": "zh-CN"}
VOID_ELEMENTS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
ASSETS = {
    "AppIcon.png": ROOT / "app/Resources/AppIcon.png",
    "path-navigation.png": ROOT / "docs/images/features/path-navigation.png",
    "split-panes.png": ROOT / "docs/images/features/split-panes.png",
    "zip-browsing.png": ROOT / "docs/images/features/zip-browsing.png",
    "installation.png": ROOT / "docs/images/features/installation.png",
}


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.references = []
        self.errors = []
        self.feature_count = 0
        self.language = None
        self.language_links = []
        self.alternates = []
        self.viewer_title = None
        self.stack = []
        self.current_language_link = None

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        inherited_language = self.stack[-1][1] if self.stack else None
        language = attrs.get("lang", inherited_language)
        if tag == "html":
            self.language = language
        if tag not in VOID_ELEMENTS:
            self.stack.append((tag, language))
        if tag == "a" and "hreflang" in attrs:
            self.current_language_link = {**attrs, "text": ""}
            self.language_links.append(self.current_language_link)
        if tag == "link" and attrs.get("rel") == "alternate":
            self.alternates.append((attrs.get("href"), attrs.get("hreflang")))
        if tag == "dialog" and attrs.get("id") == "image-dialog":
            self.viewer_title = attrs.get("data-viewer-title")
        if "id" in attrs:
            if attrs["id"] in self.ids:
                self.errors.append(f"Duplicate ID: {attrs['id']}")
            self.ids.add(attrs["id"])
        if "data-panel" in attrs:
            self.feature_count += 1
        if tag == "img" and "alt" not in attrs:
            self.errors.append("Image is missing alt text")
        if "data-viewer" in attrs and not attrs.get("data-title"):
            self.errors.append("Screenshot viewer link is missing its localized title")
        for key in ("alt", "aria-label", "data-title", "data-viewer-title", "content"):
            self.check_translation(attrs.get(key, ""), language)
        for key in ("href", "src"):
            if attrs.get(key):
                self.references.append((tag, attrs[key]))

    def check_translation(self, text, language):
        if self.language == "en" and language != "zh-CN" and re.search(r"[\u3400-\u9fff]", text):
            self.errors.append(f"Untranslated Chinese in English page: {text[:80]}")

    def handle_data(self, data):
        language = self.stack[-1][1] if self.stack else self.language
        self.check_translation(data, language)
        if self.current_language_link is not None:
            self.current_language_link["text"] += data

    def handle_endtag(self, tag):
        if tag == "a":
            self.current_language_link = None
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break


def validate():
    pages = {}
    errors = []
    for filename, language in PAGES.items():
        page = Page()
        page.feed((DIST / filename).read_text(encoding="utf-8"))
        pages[filename] = page
        errors.extend(f"{filename}: {error}" for error in page.errors)
        if page.language != language:
            errors.append(f"{filename}: expected lang={language}, found {page.language}")
        if page.feature_count != 3:
            errors.append(f"{filename}: expected three workflow panels, found {page.feature_count}")
        if not page.viewer_title:
            errors.append(f"{filename}: missing localized viewer fallback title")
        if set(page.alternates) != set(PAGES.items()):
            errors.append(f"{filename}: missing English/Chinese alternate links")
        links = page.language_links
        expected = {(name, lang, lang, "page" if name == filename else None, "English" if lang == "en" else "中文") for name, lang in PAGES.items()}
        actual = {(link.get("href"), link.get("hreflang"), link.get("lang"), link.get("aria-current"), link["text"].strip()) for link in links}
        if len(links) != 2 or actual != expected:
            errors.append(f"{filename}: language switch must link both static pages and identify the current language")
    if pages["index.html"].ids != pages["zh.html"].ids:
        errors.append("English and Chinese pages must preserve the same section anchors")
    css = (DIST / "styles.css").read_text(encoding="utf-8")
    references = [(filename, tag, ref) for filename, page in pages.items() for tag, ref in page.references]
    references += [("index.html", "style", ref.strip("\"' ")) for ref in re.findall(r"url\(([^)]+)\)", css)]
    for filename, tag, reference in references:
        parsed = urlsplit(reference)
        if parsed.scheme or parsed.netloc:
            if tag != "a" or parsed.scheme != "https" or parsed.netloc != "github.com":
                errors.append(f"Unexpected external dependency or link: {reference}")
            continue
        if parsed.path.startswith("/"):
            errors.append(f"Absolute path breaks subpath hosting: {reference}")
            continue
        relative = unquote(parsed.path or filename)
        target = (DIST / relative).resolve()
        if not target.is_relative_to(DIST.resolve()) or not target.is_file():
            errors.append(f"Missing or escaping local reference: {reference}")
        if parsed.fragment and relative in pages and unquote(parsed.fragment) not in pages[relative].ids:
            errors.append(f"{filename}: missing fragment target: {reference}")
    if errors:
        raise ValueError("\n".join(errors))
    return len(references)


def release_version():
    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", version):
        raise ValueError(f"VERSION must be a semantic version without a leading v, found {version!r}")
    return version


def substitute(text, version, filename):
    text = text.replace("{{VERSION}}", version)
    leftover = re.search(r"\{\{[A-Z_]+\}\}", text)
    if leftover:
        raise ValueError(f"{filename} has an unsubstituted placeholder {leftover.group(0)}")
    return text


def main():
    version = release_version()
    html = {filename: substitute((SITE / filename).read_text(encoding="utf-8"), version, filename)
            for filename in PAGES}
    assets = dict(ASSETS)
    for source in assets.values():
        if not source.is_file():
            raise FileNotFoundError(f"Missing canonical asset: {source.relative_to(ROOT)}")
    screenshots = sorted((ROOT / "docs/images/features").glob("*.png"))
    if not screenshots:
        raise ValueError("No canonical screenshots found")
    for source in screenshots:
        validate_screenshot_alpha(source)
    if DIST.is_symlink():
        raise ValueError("Refusing to replace a symlink at site/dist")
    if DIST.exists():
        shutil.rmtree(DIST)
    (DIST / "assets").mkdir(parents=True)
    for filename, content in html.items():
        (DIST / filename).write_text(content, encoding="utf-8")
    for filename in ("styles.css", "main.js"):
        shutil.copy2(SITE / filename, DIST / filename)
    (DIST / "install.md").write_text(
        substitute((SITE / "install.md").read_text(encoding="utf-8"), version, "install.md"), encoding="utf-8")
    for filename, source in assets.items():
        shutil.copy2(source, DIST / "assets" / filename)
    reference_count = validate()
    size = sum(path.stat().st_size for path in DIST.rglob("*") if path.is_file())
    print(f"Built site/dist for {version}: {len(PAGES)} languages, {len(assets)} canonical assets, {reference_count} references checked, {size / 1024:.0f} KiB; {len(screenshots)} screenshots passed alpha checks.")
    print("Preview: python3 -m http.server 8080 --directory site/dist")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        sys.exit(1)
