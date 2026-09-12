#!/usr/bin/env python3
"""Extract one complete, nonempty version section for GitHub release notes."""

import argparse
from pathlib import Path
import posixpath
import re
from urllib.parse import quote, urlsplit, urlunsplit


VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?"
REFERENCE = re.compile(r"^ {0,3}\[([^\]]+)\]:[ \t]+(.+?)[ \t]*$")


def markdown_lines(markdown: str):
    """Keep source lines intact while masking fences/comments for structure.

    This intentionally handles the constructs used by our changelog, without
    rendering Markdown or treating example headings as release boundaries.
    """
    fence = None
    comment = False
    for raw in markdown.splitlines(keepends=True):
        line = raw.rstrip("\r\n")
        if fence:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(fence[1]) + r",}[ \t]*", line):
                fence = None
                yield raw, "", "fence"
            else:
                yield raw, line, "code"
            continue
        if not comment:
            opening = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
            if opening and (opening[1][0] != "`" or "`" not in opening[2]):
                fence = (opening[1][0], len(opening[1]))
                yield raw, "", "fence"
                continue
        visible = []
        index = 0
        while index < len(line):
            if comment:
                end = line.find("-->", index)
                if end < 0:
                    visible.append(" " * (len(line) - index))
                    break
                visible.append(" " * (end + 3 - index))
                index = end + 3
                comment = False
            else:
                start = line.find("<!--", index)
                if start < 0:
                    visible.append(line[index:])
                    break
                visible.append(line[index:start])
                index = start
                comment = True
        yield raw, "".join(visible), "text"


def normalized_label(label: str) -> str:
    return " ".join(label.split()).casefold()


def outside_inline_code(line: str, transform):
    """Transform ordinary spans, preserving matched backtick code spans."""
    output = []
    index = 0
    for opening in re.finditer(r"`+", line):
        if opening.start() < index:
            continue
        closing = re.search(r"(?<!`)" + re.escape(opening[0]) + r"(?!`)", line[opening.end():])
        if not closing:
            continue
        end = opening.end() + closing.end()
        output.append(transform(line[index:opening.start()]))
        output.append(line[opening.start():end])
        index = end
    output.append(transform(line[index:]))
    return "".join(output)


def used_reference_labels(markdown: str) -> set[str]:
    used = set()
    def collect(span):
        for match in re.finditer(r"\[([^\]\n]+)\](?:\[([^\]\n]*)\])?", span):
            if span[match.end():].startswith(("(", ":")):
                continue
            used.add(normalized_label(match[2] or match[1]))
        return span
    for _, visible, kind in markdown_lines(markdown):
        if kind == "text" and not REFERENCE.fullmatch(visible):
            outside_inline_code(visible, collect)
    return used


def extract_notes(changelog: str, version: str) -> str:
    if not re.fullmatch(VERSION, version):
        raise ValueError("Expected a release version without a leading v")
    lines = list(markdown_lines(changelog))
    headings = [(i, visible) for i, (_, visible, kind) in enumerate(lines)
                if kind == "text" and re.fullmatch(r"## .+", visible)]
    target = re.compile(r"## \[" + re.escape(version) + r"\] - \d{4}-\d{2}-\d{2}$")
    matches = [i for i, (_, heading) in enumerate(headings) if target.fullmatch(heading)]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one dated changelog section for {version}")
    index = matches[0]
    start = headings[index][0] + 1
    end = headings[index + 1][0] if index + 1 < len(headings) else len(lines)
    body = "".join(raw for raw, _, _ in lines[start:end]).strip()
    used = used_reference_labels(body)
    definitions = {}
    for raw, visible, kind in lines:
        definition = REFERENCE.fullmatch(visible) if kind == "text" else None
        if definition:
            definitions.setdefault(normalized_label(definition[1]), raw.rstrip("\r\n"))
    kept = []
    included = set()
    content = False
    for raw, visible, kind in markdown_lines(body):
        definition = REFERENCE.fullmatch(visible) if kind == "text" else None
        if definition:
            label = normalized_label(definition[1])
            if label in used:
                kept.append(raw)
                included.add(label)
            continue
        kept.append(raw)
        if kind == "code" and visible.strip():
            content = True
        elif kind == "text" and visible.strip() and not re.match(r"^ {0,3}#+(?:\s|$)", visible):
            content = True
    if not content:
        raise ValueError(f"The changelog section for {version} is empty")
    body = "".join(kept).strip()
    # Definitions may live below later releases; include only those used by
    # this body so reference links survive without changelog navigation noise.
    missing = [raw for label, raw in definitions.items() if label in used and label not in included]
    if missing:
        body += "\n\n" + "\n".join(missing)
    return body + "\n"


def destination_span(text: str, start: int):
    """Locate one Markdown destination, leaving optional titles untouched."""
    while start < len(text) and text[start] in " \t":
        start += 1
    if start >= len(text):
        return None
    if text[start] == "<":
        end = text.find(">", start + 1)
        return (start + 1, end) if end >= 0 else None
    depth = 0
    end = start
    while end < len(text):
        char = text[end]
        if char == "\\" and end + 1 < len(text):
            end += 2
            continue
        if char in " \t\r\n" or (char == ")" and depth == 0):
            break
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        end += 1
    return (start, end) if end > start and depth == 0 else None


def rewrite_repository_links(markdown: str, repository: str, ref: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or any(part in (".", "..") for part in repository.split("/")):
        raise ValueError("Expected --repository in owner/name form")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", ref) or ".." in ref or ref.endswith("/"):
        raise ValueError("Expected --ref to be a commit SHA, tag or branch name")
    base = f"https://github.com/{repository}/blob/{quote(ref, safe='')}/"

    def rewrite(url):
        if url.startswith(("#", "/")):
            return url
        unescaped = re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~ ])", r"\1", url)
        parts = urlsplit(unescaped)
        if parts.scheme or parts.netloc or not parts.path:
            return url
        path = posixpath.normpath(parts.path)
        if path == ".." or path.startswith("../"):
            raise ValueError("A changelog link escapes the repository root")
        return urlunsplit(("https", "github.com", urlsplit(base).path + quote(path, safe="/%:@!$&'*+,;=-._~"), parts.query, parts.fragment))

    def replace_span(text, span):
        if span is None:
            return text
        start, end = span
        return text[:start] + rewrite(text[start:end]) + text[end:]

    def inline_links(text):
        spans = []
        for match in re.finditer(r"\]\(", text):
            span = destination_span(text, match.end())
            if span:
                spans.append(span)
        for span in reversed(spans):
            text = replace_span(text, span)
        return text

    output = []
    for raw, visible, kind in markdown_lines(markdown):
        if kind != "text" or visible != raw.rstrip("\r\n"):
            output.append(raw)
            continue
        definition = REFERENCE.fullmatch(visible)
        if definition:
            start = definition.start(2)
            output.append(replace_span(raw, destination_span(raw, start)))
        else:
            output.append(outside_inline_code(raw, inline_links))
    return "".join(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", help="GitHub owner/name for repository-relative links")
    parser.add_argument("--ref", help="Exact commit SHA or tag used by repository-relative links")
    args = parser.parse_args()
    try:
        if bool(args.repository) != bool(args.ref):
            raise ValueError("--repository and --ref must be supplied together")
        if args.output.resolve() == args.changelog.resolve() or (
            args.output.exists() and args.changelog.exists() and args.output.samefile(args.changelog)
        ):
            raise ValueError("The release notes output must not replace the changelog")
        notes = extract_notes(args.changelog.read_text(encoding="utf-8"), args.version)
        if args.repository:
            notes = rewrite_repository_links(notes, args.repository, args.ref)
        args.output.write_text(notes, encoding="utf-8")
    except (ValueError, OSError) as error:
        parser.exit(1, f"Release notes error: {error}\n")


if __name__ == "__main__":
    main()
