#!/usr/bin/env python3
"""Add an integer offset to every vertex label in a facet array.

Examples (from Experimental/SageMath):
    python3 extras/shift_vertex_labels.py --facets '[[1,2,3],[2,3,4]]' --shift 2
    python3 extras/shift_vertex_labels.py --input knots/ball.txt --shift 2 -o outputs/shifted.txt

Without --output, print the resulting array. Input files are never modified.
"""

import argparse
from pathlib import Path

from format_facets import format_facets, parse_facets


def shift_vertex_labels(facets, shift):
    """Return a new facet array, preserving facet and vertex order."""
    if type(shift) is not int:
        raise ValueError("The shift must be an integer")
    if not isinstance(facets, (list, tuple)):
        raise ValueError("Facets must be a list or tuple")
    result = []
    for index, facet in enumerate(facets, start=1):
        if not isinstance(facet, (list, tuple)):
            raise ValueError(f"Facet {index} must be a list or tuple")
        if any(type(vertex) is not int for vertex in facet):
            raise ValueError(f"Facet {index} contains a non-integer vertex label")
        result.append([vertex + shift for vertex in facet])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--facets", help="Facet array as a quoted string")
    source.add_argument("--input", type=Path, help="File containing a facet array")
    parser.add_argument("--shift", required=True, type=int, help="Amount to add to each label")
    parser.add_argument("-o", "--output", type=Path, help="Save the result instead of printing it")
    args = parser.parse_args()
    if args.input and args.output and args.input.resolve() == args.output.resolve():
        parser.error("Output must differ from the input file")
    try:
        text = args.input.read_text(encoding="utf-8") if args.input else args.facets
        result = format_facets(shift_vertex_labels(parse_facets(text), args.shift))
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(result, encoding="utf-8")
        else:
            print(result, end="")
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
