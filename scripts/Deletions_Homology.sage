"""Find vertex deletion sets whose remaining complex has trivial homology.

Run from the project root with
FACETS_FILE=/path/to/facets.txt sage scripts/Deletions_Homology.sage.
Results are saved as JSON in outputs/<name>_potential_cases.txt.
"""

import ast
import json
import os
from itertools import combinations
from math import comb
from pathlib import Path

from sage.all import SimplicialComplex


def load_facets_from_file(path):
    with open(path, "r") as f:
        text = f.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return ast.literal_eval(text)


def delete_vertices(K, vs):
    """Delete vertices from a fresh copy, leaving K unchanged."""
    new_K = SimplicialComplex(K.facets())
    new_K.remove_faces([[v] for v in vs])
    return SimplicialComplex(new_K.facets())


def has_trivial_homology(K):
    # Sage computes reduced homology by default, including connectivity in H_0.
    hom = K.homology()
    # Sage returns group objects; check that every group is displayed as 0.
    return all(str(h) == "0" for h in hom.values())


def find_potential_cases(original_complex):
    """Return unordered deletion tuples leaving trivial reduced homology."""
    vertices = tuple(original_complex.vertices())
    # For an odd vertex count, round the half down before subtracting one.
    delete_n = len(vertices) // 2 - 1
    if delete_n < 0:
        raise ValueError("The complex must have at least two vertices.")

    print(f"Vertices: {len(vertices)}", flush=True)
    print(f"Vertices to delete: {delete_n}", flush=True)
    print(f"Total combinations: {comb(len(vertices), delete_n)}", flush=True)

    potential_cases = []
    for deletion in combinations(vertices, delete_n):
        remaining_complex = delete_vertices(original_complex, deletion)
        if has_trivial_homology(remaining_complex):
            potential_cases.append(deletion)

    return potential_cases


if __name__ == "__main__":
    facets_file = os.environ.get("FACETS_FILE")
    if not facets_file:
        raise SystemExit("Set FACETS_FILE to the path of your facets file.")

    facets = load_facets_from_file(facets_file)
    ORIGINAL_SIMPLICIAL = SimplicialComplex(facets)
    potential_cases = find_potential_cases(ORIGINAL_SIMPLICIAL)
    output_dir = Path("outputs")
    output_dir.mkdir(parents=True, exist_ok=True)
    name = Path(os.environ.get("KNOT_NAME") or facets_file).stem
    output_file = output_dir / f"{name}_potential_cases.txt"
    with output_file.open("w") as f:
        json.dump(potential_cases, f, indent=2)
        f.write("\n")

    print(f"Potential cases with trivial homology: {len(potential_cases)}")
    print(f"Saved potential cases to: {output_file}")
