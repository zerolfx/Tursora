"""Regression checks for extracting the exact Markdown used in a release."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release-notes.py")
SPEC = importlib.util.spec_from_file_location("tursora_release_notes", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
extract_notes = MODULE.extract_notes
rewrite_repository_links = MODULE.rewrite_repository_links


class ExtractNotesTests(unittest.TestCase):
    def test_extracts_only_the_requested_dated_section(self):
        changelog = """# Changelog

## [Unreleased]

- Future work.

## [0.2.0] - 2026-09-15

### Added

- Current release.

## [0.1.0] - 2026-09-12

- Earlier release.
"""
        self.assertEqual(extract_notes(changelog, "0.2.0"), "### Added\n\n- Current release.\n")
        self.assertEqual(extract_notes(changelog, "0.1.0"), "- Earlier release.\n")

    def test_preserves_actual_markdown_and_unicode(self):
        body = """### Added

- **Split panes** keep `Left | Right` names.
  - 中文说明 with *emphasis* and a [guide](docs/guide.md "Guide title").

> A quoted explanation.

| Feature | Status |
| --- | --- |
| Search | Ready |

```sh
printf '%s\\n' 'literal \\t stays literal'
```

<!-- A useful release comment. -->
"""
        self.assertEqual(extract_notes("## [0.1.0] - 2026-09-12\n\n" + body, "0.1.0"), body)

    def test_normalizes_only_outer_whitespace_and_final_newline(self):
        self.assertEqual(
            extract_notes("## [0.1.0] - 2026-09-12\n\n\nParagraph.\n\nSecond paragraph.\n\n\n", "0.1.0"),
            "Paragraph.\n\nSecond paragraph.\n",
        )

    def test_accepts_prerelease_and_matches_it_exactly(self):
        changelog = """## [0.2.0-beta.1] - 2026-09-15

- Beta one.

## [0.2.0-beta.10] - 2026-09-14

- A different prerelease.

## [0.2.0] - 2026-09-13

- Stable.
"""
        self.assertEqual(extract_notes(changelog, "0.2.0-beta.1"), "- Beta one.\n")

    def test_rejects_invalid_version_arguments(self):
        for version in ("v0.1.0", "0.1", "00.1.0", "0.01.0", "0.1.00", "0.1.0-", "0.1.0 beta", "0.1.0\n", "../0.1.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                extract_notes("## [0.1.0] - 2026-09-12\n\n- Valid body.\n", version)

    def test_rejects_a_missing_or_undated_target(self):
        for changelog in ("", "## [Unreleased]\n\n- Later.\n", "## [0.1.0]\n\n- Undated.\n", "## [0.1.00] - 2026-09-12\n\n- Wrong version.\n"):
            with self.subTest(changelog=changelog), self.assertRaises(ValueError):
                extract_notes(changelog, "0.1.0")

    def test_rejects_duplicate_target_sections_even_with_different_dates(self):
        changelog = """## [0.1.0] - 2026-09-12

- First copy.

## [0.1.0] - 2026-09-13

- Second copy.
"""
        with self.assertRaises(ValueError):
            extract_notes(changelog, "0.1.0")

    def test_rejects_empty_or_heading_comment_reference_only_sections(self):
        for body in ("", " \n\t\n", "### Added\n\n### Fixed\n", "<!-- Pending release notes. -->", "### Added\n<!-- Pending\nnotes. -->\n", "[0.1.0]: https://example.com/releases/0.1.0\n"):
            with self.subTest(body=body), self.assertRaises(ValueError):
                extract_notes("## [0.1.0] - 2026-09-12\n\n" + body, "0.1.0")

    def test_removes_unused_trailing_changelog_reference_definitions(self):
        changelog = """## [0.1.0] - 2026-09-12

- First release.

[Unreleased]: https://example.com/compare/HEAD
[0.1.0]: https://example.com/releases/0.1.0
"""
        self.assertEqual(extract_notes(changelog, "0.1.0"), "- First release.\n")

    def test_preserves_reference_definitions_used_by_release_markdown(self):
        changelog = """## [0.1.0] - 2026-09-12

Read the [migration guide][guide] before updating.

[guide]: https://example.com/guide "Migration guide"
[0.1.0]: https://example.com/releases/0.1.0
"""
        expected = "Read the [migration guide][guide] before updating.\n\n[guide]: https://example.com/guide \"Migration guide\"\n"
        self.assertEqual(extract_notes(changelog, "0.1.0"), expected)

    def test_fenced_markdown_headings_do_not_end_a_release(self):
        for fence in ("```", "~~~~"):
            body = f"""Example documentation:

{fence}markdown
## This is an example heading

[literal]: text that belongs to the example
{fence}

- The release continues here.
"""
            changelog = "## [0.1.0] - 2026-09-12\n\n" + body + "\n## [0.0.9] - 2026-09-11\n\n- Older.\n"
            with self.subTest(fence=fence):
                self.assertEqual(extract_notes(changelog, "0.1.0"), body)

    def test_example_version_heading_inside_a_fence_is_not_a_duplicate(self):
        changelog = """## [0.1.0] - 2026-09-12

```markdown
## [0.1.0] - 2026-09-12
```

- Actual content.
"""
        self.assertEqual(extract_notes(changelog, "0.1.0"), "```markdown\n## [0.1.0] - 2026-09-12\n```\n\n- Actual content.\n")

    def test_headings_in_comments_are_not_release_boundaries(self):
        body = "<!--\n## [0.1.0] - 2026-09-12\n-->\n\n- Actual content.\n"
        self.assertEqual(extract_notes("## [0.1.0] - 2026-09-12\n\n" + body, "0.1.0"), body)

    def test_reference_used_in_selected_section_can_live_after_older_releases(self):
        changelog = """## [0.2.0] - 2026-09-15

Read the [guide][shared].

## [0.1.0] - 2026-09-12

- Older release.

[shared]: docs/GUIDE.md
[0.2.0]: https://example.com/releases/0.2.0
"""
        self.assertEqual(extract_notes(changelog, "0.2.0"), "Read the [guide][shared].\n\n[shared]: docs/GUIDE.md\n")


class RepositoryLinksTests(unittest.TestCase):
    def rewrite(self, markdown):
        return rewrite_repository_links(markdown, "zerolfx/Tursora", "abc123def")

    def test_relative_links_use_exact_repository_commit_and_preserve_titles(self):
        self.assertEqual(
            self.rewrite('[Handoff](docs/HANDOFF.md#limits "Current limits") and [History](./docs/DEVELOPMENT_HISTORY.md).\n'),
            '[Handoff](https://github.com/zerolfx/Tursora/blob/abc123def/docs/HANDOFF.md#limits "Current limits") and [History](https://github.com/zerolfx/Tursora/blob/abc123def/docs/DEVELOPMENT_HISTORY.md).\n',
        )

    def test_keeps_absolute_links_and_same_page_anchors(self):
        markdown = "[Web](https://example.com/a?b=1#c) [Mail](mailto:team@example.com) [Anchor](#limits) [Site](/about) [CDN](//example.com/file).\n"
        self.assertEqual(self.rewrite(markdown), markdown)

    def test_code_examples_are_not_rewritten(self):
        markdown = "`[Example](docs/example.md)` and ``a ` [Example](docs/example.md)``.\n\n```markdown\n[Example](docs/example.md)\n```\n"
        self.assertEqual(self.rewrite(markdown), markdown)

    def test_reference_definition_preserves_markdown_title(self):
        self.assertEqual(
            self.rewrite('[Guide][guide]\n\n[guide]: docs/GUIDE.md "Read this"\n'),
            '[Guide][guide]\n\n[guide]: https://github.com/zerolfx/Tursora/blob/abc123def/docs/GUIDE.md "Read this"\n',
        )

    def test_handles_spaces_parentheses_and_existing_percent_encoding(self):
        self.assertEqual(
            self.rewrite('[One](<docs/My Guide.md> "Guide") [Two](docs/Plan_(final).md) [Three](docs/My%20Guide.md).\n'),
            '[One](<https://github.com/zerolfx/Tursora/blob/abc123def/docs/My%20Guide.md> "Guide") [Two](https://github.com/zerolfx/Tursora/blob/abc123def/docs/Plan_%28final%29.md) [Three](https://github.com/zerolfx/Tursora/blob/abc123def/docs/My%20Guide.md).\n',
        )

    def test_reference_labels_can_contain_colons(self):
        self.assertEqual(
            self.rewrite('[Guide][docs:guide]\n\n[docs:guide]: docs/GUIDE.md "Guide"\n'),
            '[Guide][docs:guide]\n\n[docs:guide]: https://github.com/zerolfx/Tursora/blob/abc123def/docs/GUIDE.md "Guide"\n',
        )

    def test_escaped_parentheses_remain_part_of_the_link_destination(self):
        self.assertEqual(
            self.rewrite('[Guide](docs/Plan\\).md)'),
            '[Guide](https://github.com/zerolfx/Tursora/blob/abc123def/docs/Plan%29.md)',
        )

    def test_tag_refs_and_repository_internal_parent_segments(self):
        self.assertEqual(
            rewrite_repository_links('[Guide](docs/../README.md)', "zerolfx/Tursora", "v0.2.0-beta.1"),
            '[Guide](https://github.com/zerolfx/Tursora/blob/v0.2.0-beta.1/README.md)',
        )

    def test_rejects_links_that_escape_the_repository(self):
        with self.assertRaises(ValueError):
            self.rewrite('[Outside](../another-repository/README.md)')

    def test_rejects_invalid_repository_and_ref_arguments(self):
        for repository, ref in (("not-a-repository", "abc123"), ("../Tursora", "abc123"), ("zerolfx/Tursora", ""), ("zerolfx/Tursora", "main#fragment"), ("zerolfx/Tursora", "../main")):
            with self.subTest(repository=repository, ref=ref), self.assertRaises(ValueError):
                rewrite_repository_links('[Guide](docs/GUIDE.md)', repository, ref)


class ReleaseNotesCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tursora-release-notes-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.changelog = self.directory / "CHANGELOG.md"
        self.output = self.directory / "release body.md"

    def invoke(self, version="0.1.0", extra=()):
        return subprocess.run(
            [sys.executable, str(SCRIPT), version, "--changelog", str(self.changelog), "--output", str(self.output), *extra],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_writes_utf8_markdown_with_actual_newlines(self):
        self.changelog.write_text("## [0.1.0] - 2026-09-12\n\n### Added\n\n- 中文。\n- Second line.\n", encoding="utf-8")
        original = self.changelog.read_bytes()
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.output.read_bytes(), "### Added\n\n- 中文。\n- Second line.\n".encode("utf-8"))
        self.assertEqual(self.changelog.read_bytes(), original)

    def test_handles_normal_crlf_changelogs(self):
        self.changelog.write_bytes(b"## [0.1.0] - 2026-09-12\r\n\r\n- Windows line endings.\r\n")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), b"- Windows line endings.\n")

    def test_invalid_release_does_not_create_output(self):
        self.changelog.write_text("## [Unreleased]\n\n- Future.\n", encoding="utf-8")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release notes error:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.output.exists())

    def test_failed_extraction_preserves_an_existing_output(self):
        self.changelog.write_text("## [0.1.0] - 2026-09-12\n\n<!-- Empty. -->\n", encoding="utf-8")
        self.output.write_text("Existing notes.\n", encoding="utf-8")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "Existing notes.\n")

    def test_missing_input_reports_a_controlled_error(self):
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release notes error:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.output.exists())

    def test_unwritable_output_reports_a_controlled_error(self):
        self.changelog.write_text("## [0.1.0] - 2026-09-12\n\n- Ready.\n", encoding="utf-8")
        self.output = self.directory / "missing parent" / "notes.md"
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release notes error:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_cli_rewrites_links_using_explicit_repository_and_ref(self):
        self.changelog.write_text("## [0.1.0] - 2026-09-12\n\nRead [Handoff](docs/HANDOFF.md).\n", encoding="utf-8")
        result = self.invoke(extra=("--repository", "zerolfx/Tursora", "--ref", "abc123def"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "Read [Handoff](https://github.com/zerolfx/Tursora/blob/abc123def/docs/HANDOFF.md).\n")

    def test_repository_and_ref_must_be_supplied_together(self):
        self.changelog.write_text("## [0.1.0] - 2026-09-12\n\n- Ready.\n", encoding="utf-8")
        for options in (("--repository", "zerolfx/Tursora"), ("--ref", "abc123def")):
            with self.subTest(options=options):
                result = self.invoke(extra=options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be supplied together", result.stderr)
                self.assertFalse(self.output.exists())

    def test_output_cannot_replace_input_through_the_same_path_or_a_symlink(self):
        self.changelog.write_text("## [0.1.0] - 2026-09-12\n\n- Ready.\n", encoding="utf-8")
        original = self.changelog.read_bytes()
        alias = self.directory / "changelog-alias.md"
        alias.symlink_to(self.changelog)
        for output in (self.changelog, alias):
            with self.subTest(output=output):
                self.output = output
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must not replace the changelog", result.stderr)
                self.assertEqual(self.changelog.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
