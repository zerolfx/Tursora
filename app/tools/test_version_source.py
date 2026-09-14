"""The repository names its version once, in VERSION.

Before this guard the current version was repeated in the README, both product
pages and the installation guide, and it drifted: the spec still described 0.2.0
as the published release two releases later. These checks fail if a release
starts editing prose again instead of the single source.
"""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEMVER = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$")
# Prose that must never spell out the current version. The site pages and the
# installation guide carry the {{VERSION}} placeholder, which the site build
# substitutes; the README is rendered raw by GitHub, so it cannot name the
# current version at all. Dependency versions (SwiftTerm, Sparkle, Swift) and
# references to past releases are unaffected: only the version being shipped
# would go stale.
#
# One kind of sentence names the current version on purpose: "New in 0.3.0"
# records when a feature arrived and must NOT follow later releases, which is
# exactly what the placeholder would do. Those lines carry HISTORICAL_MARKER,
# and the line it precedes is exempt. No regex can tell "the version you
# download" from "the version this arrived in", so the distinction is declared.
PLACEHOLDER_FILES = ("site/index.html", "site/zh.html", "site/install.md")
VERSIONLESS_FILES = ("README.md",)
HISTORICAL_MARKER = "<!-- historical-version -->"


def without_historical_lines(text):
    """Drop lines marked as recording when a feature arrived, and the line after."""
    kept, skip_next = [], False
    for line in text.split("\n"):
        if HISTORICAL_MARKER in line:
            skip_next = True
            continue
        if skip_next:
            skip_next = False
            continue
        kept.append(line)
    return "\n".join(kept)


class VersionSource(unittest.TestCase):
    def setUp(self):
        self.version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()

    def test_version_file_is_a_semantic_version(self):
        self.assertRegex(self.version, SEMVER)

    def test_packaging_script_reads_the_version_file(self):
        script = (ROOT / "app/tools/make-app.sh").read_text(encoding="utf-8")
        self.assertIn('VERSION="${TURSORA_VERSION:-$(tr -d "[:space:]" < "$ROOT/../VERSION")}"', script)
        self.assertNotRegex(script, r'TURSORA_VERSION:-\d')

    def test_packaged_bundle_uses_the_version_file(self):
        """The default really resolves, rather than only looking right."""
        resolved = subprocess.run(
            ["bash", "-c", 'ROOT="$1"; echo "${TURSORA_VERSION:-$(tr -d "[:space:]" < "$ROOT/../VERSION")}"',
             "_", str(ROOT / "app")],
            capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(resolved, self.version)

    def test_prose_does_not_repeat_the_current_version(self):
        for name in PLACEHOLDER_FILES + VERSIONLESS_FILES:
            with self.subTest(file=name):
                text = without_historical_lines((ROOT / name).read_text(encoding="utf-8"))
                self.assertNotIn(self.version, text,
                                 f"{name} names the current version; use {{{{VERSION}}}} or drop it")

    def test_historical_marker_only_exempts_a_real_version_line(self):
        """A marker that shields no version would silently weaken the guard."""
        for name in PLACEHOLDER_FILES:
            text = (ROOT / name).read_text(encoding="utf-8")
            lines = text.split("\n")
            for index, line in enumerate(lines):
                if HISTORICAL_MARKER not in line:
                    continue
                with self.subTest(file=name, line=index + 1):
                    self.assertLess(index + 1, len(lines), "marker has no line to exempt")
                    self.assertRegex(lines[index + 1], r"\d+\.\d+\.\d+",
                                     "the marked line names no version, so the marker is dead")

    def test_placeholder_files_use_the_placeholder(self):
        for name in PLACEHOLDER_FILES:
            with self.subTest(file=name):
                self.assertIn("{{VERSION}}", (ROOT / name).read_text(encoding="utf-8"))

    def test_changelog_documents_the_current_version(self):
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertRegex(changelog, rf"(?m)^## \[{re.escape(self.version)}\] - \d{{4}}-\d{{2}}-\d{{2}}$",
                         msg="VERSION must have a dated changelog section")


if __name__ == "__main__":
    unittest.main()
