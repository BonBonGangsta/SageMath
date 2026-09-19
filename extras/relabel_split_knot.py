#!/usr/bin/env python3
"""Relabel a barycentric subdivision after splitting knot edge [1, 2] at 3.

Usage:
    python3 extras/relabel_split_knot.py subdivision.txt
    python3 extras/relabel_split_knot.py subdivision.txt --midpoints 1,2 2,3

Input is a Python literal list, tuple, or set of facets whose vertices are
face tuples, e.g. [(1,), (1,3), (1,3,7), (1,3,7,8)]. JSON lists also work.
Supply the subdivision AFTER the manual split. Original facets are not needed.
The default knot path is 1--3--2; --midpoints specifies the two face labels
to receive 4 and 5, respectively, if a different path was used.
"""

import argparse
import ast
import json
from pathlib import Path


def relabel(facets, midpoints=((1, 3), (2, 3))):
    """Return sorted integer facets and the bijective face-to-label mapping."""
    def face_key(face):
        if not isinstance(face, (list, tuple, set, frozenset)) or not face:
            raise ValueError(f"Expected a nonempty face tuple/list, got {face!r}")
        if any(type(v) is not int for v in face):
            raise ValueError(f"Face labels must contain integers: {face!r}")
        if len(set(face)) != len(face):
            raise ValueError(f"Repeated vertex in face: {face!r}")
        return tuple(sorted(face))

    if not isinstance(facets, (list, tuple, set, frozenset)) or not facets:
        raise ValueError("Expected a nonempty collection of subdivision facets")
    normalized = []
    for facet in facets:
        if not isinstance(facet, (list, tuple, set, frozenset)) or not facet:
            raise ValueError("Each facet must be a nonempty collection of face labels")
        faces = tuple(face_key(face) for face in facet)
        if len(set(faces)) != len(faces):
            raise ValueError(f"Repeated subdivision vertex in facet: {facet!r}")
        normalized.append(faces)
    vertices = {face for facet in normalized for face in facet}
    midpoints = tuple(face_key(face) for face in midpoints)
    if (len(midpoints) != 2 or len(set(midpoints)) != 2
            or any(len(face) != 2 or not set(face) <= {1, 2, 3}
                   for face in midpoints)):
        raise ValueError("Specify two distinct knot edges among vertices 1, 2, 3")
    mapping = {(1,): 1, (2,): 2, (3,): 3,
               midpoints[0]: 4, midpoints[1]: 5}
    missing = set(mapping) - vertices
    if missing:
        raise ValueError(f"Required knot vertices/midpoints absent: {sorted(missing)}")
    # Retain a stable order: other original vertices first, then higher faces.
    remaining = sorted(vertices - mapping.keys(), key=lambda face: (len(face), face))
    mapping.update((face, label) for label, face in enumerate(remaining, start=6))
    converted = sorted({tuple(sorted(mapping[face] for face in facet))
                        for facet in normalized})
    return converted, mapping


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", type=Path, help="File containing only subdivision facets")
    parser.add_argument("-o", "--output", type=Path,
                        help="Default: <input stem>_relabeled.txt beside the input")
    parser.add_argument("--midpoints", nargs=2, default=["1,3", "2,3"],
                        metavar=("EDGE_FOR_4", "EDGE_FOR_5"))
    args = parser.parse_args()
    output = args.output or args.input.with_name(args.input.stem + "_relabeled.txt")
    mapping_path = output.with_name(output.stem + "_mapping.json")
    if args.input.resolve() in {output.resolve(), mapping_path.resolve()}:
        parser.error("Output files must differ from the input file")
    try:
        facets = ast.literal_eval(args.input.read_text(encoding="utf-8"))
        midpoints = [tuple(int(v.strip()) for v in edge.split(","))
                     for edge in args.midpoints]
        converted, mapping = relabel(facets, midpoints)
    except (OSError, ValueError, SyntaxError, TypeError) as error:
        parser.error(str(error))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(converted) + "\n", encoding="utf-8")
    records = [{"face": face, "label": label} for face, label in mapping.items()]
    mapping_path.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(converted)} facets, {len(mapping)} vertices: {output}")
    print(f"Label mapping: {mapping_path}")


if __name__ == "__main__":
    main()
