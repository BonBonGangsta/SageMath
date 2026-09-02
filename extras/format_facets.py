#!/usr/bin/env python3
"""Format a facet-array text file with one facet per line.

Accepted inputs include JSON/Python literal arrays, comma-separated facets,
and the GAP-style ``facets:=[...];`` files in the Lutz triangulation library.
The output is a Python literal that ``knot_nonevasive_v11.sage`` can load.

Examples:
    python3 scripts/format_facets.py knots/example.txt
    python3 scripts/format_facets.py knots/example.txt -o knots/readable.txt
    python3 scripts/format_facets.py knots/example.txt --in-place
"""

import argparse
import ast
import json
import os
from pathlib import Path
import re
import tempfile


def extract_facet_literal(text):
    """Return the array portion of plain or GAP-style facet text."""
    assignment = re.search(r"\bfacets\s*(?::=|=)\s*", text, re.IGNORECASE)
    if assignment is None:
        return text.strip()

    literal = text[assignment.end():].strip()
    if ";" in literal:
        literal = literal.split(";", 1)[0].rstrip()
    return literal


def parse_facets(text):
    """Parse and validate a sequence of facets without executing code."""
    literal = extract_facet_literal(text.lstrip("\ufeff"))
    if not literal:
        raise ValueError("the input does not contain a facet array")

    try:
        parsed = json.loads(literal)
    except json.JSONDecodeError:
        try:
            parsed = ast.literal_eval(literal)
        except (SyntaxError, ValueError) as exc:
            raise ValueError(
                "could not parse the input as JSON, a Python literal, "
                "or a GAP facets:=[...]; assignment"
            ) from exc

    if not isinstance(parsed, (list, tuple)):
        raise ValueError("the top-level facet collection must be a list or tuple")

    facets = []
    for index, facet in enumerate(parsed, start=1):
        if not isinstance(facet, (list, tuple)):
            raise ValueError(
                f"facet {index} must be a list or tuple, not "
                f"{type(facet).__name__}"
            )
        facets.append(list(facet))

    return facets


def format_facets(facets, indent=2):
    """Return a readable Python literal with one facet on each line."""
    padding = " " * indent
    lines = ["["]
    for index, facet in enumerate(facets):
        comma = "," if index + 1 < len(facets) else ""
        lines.append(f"{padding}{facet!r}{comma}")
    lines.append("]")
    return "\n".join(lines) + "\n"


def default_output_path(input_path):
    suffix = input_path.suffix or ".txt"
    return input_path.with_name(f"{input_path.stem}_formatted{suffix}")


def write_text_atomically(path, text):
    """Write a complete file before replacing the destination."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary_file:
            temporary_file.write(text)
            temporary_name = temporary_file.name
        os.replace(temporary_name, path)
    finally:
        if temporary_name is not None and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def build_argument_parser():
    parser = argparse.ArgumentParser(
        description="Format a facet array with one facet per line."
    )
    parser.add_argument("input", type=Path, help="facet text file to read")
    destination = parser.add_mutually_exclusive_group()
    destination.add_argument(
        "-o", "--output", type=Path, help="output file path"
    )
    destination.add_argument(
        "--in-place",
        action="store_true",
        help="replace the input file atomically",
    )
    parser.add_argument(
        "--indent",
        type=int,
        default=2,
        help="spaces before each facet (default: 2)",
    )
    return parser


def main():
    parser = build_argument_parser()
    args = parser.parse_args()

    if args.indent < 0:
        parser.error("--indent cannot be negative")

    input_path = args.input.expanduser().resolve()
    if not input_path.is_file():
        parser.error(f"input file does not exist: {input_path}")

    if args.in_place:
        output_path = input_path
    elif args.output is not None:
        output_path = args.output.expanduser().resolve()
    else:
        output_path = default_output_path(input_path)

    try:
        facets = parse_facets(input_path.read_text(encoding="utf-8"))
        formatted_text = format_facets(facets, indent=args.indent)
        write_text_atomically(output_path, formatted_text)
    except (OSError, UnicodeError, ValueError) as exc:
        parser.exit(2, f"error: {exc}\n")

    print(
        f"Formatted {len(facets)} facets: "
        f"{input_path} -> {output_path}"
    )


if __name__ == "__main__":
    main()
