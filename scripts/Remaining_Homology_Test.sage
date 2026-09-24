"""Test each remaining vertex deletion separately for every potential case.

Run from the project root:
FACETS_FILE=knots/b_12_38.txt sage scripts/Remaining_Homology_Test.sage
Set POTENTIAL_CASES_FILE below to the matching deletion results file.
"""

import ast
import json
import os
from pathlib import Path

from sage.all import SimplicialComplex


POTENTIAL_CASES_FILE = Path("outputs/B14_51_69_potential_cases.txt")


def load_facets_from_file(path):
    with open(path, "r") as f:
        text = f.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return ast.literal_eval(text)


def delete_vertices(K, vertices):
    """Delete from a fresh copy so the starting complex stays unchanged."""
    remaining = SimplicialComplex(K.facets())
    remaining.remove_faces([[v] for v in vertices])
    return SimplicialComplex(remaining.facets())


def report_remaining_homology(original_complex, potential_cases, report=print):
    original_vertices = set(original_complex.vertices())
    for case_number, case in enumerate(potential_cases, start=1):
        if len(set(case)) != len(case):
            raise ValueError(f"Potential case {case_number} repeats a vertex: {case}")
        unknown = set(case) - original_vertices
        if unknown:
            raise ValueError(
                f"Potential case {case_number} contains vertices absent "
                f"from the original complex: {unknown}"
            )

    for case_number, case in enumerate(potential_cases, start=1):
        # Every potential case starts from the original complex.
        case_complex = delete_vertices(original_complex, case)
        remaining_vertices = list(case_complex.vertices())
        report(f"Potential case {case_number}: {list(case)}")
        report(f"Remaining vertices: {remaining_vertices}")

        for vertex in remaining_vertices:
            # Every single-vertex test starts from the same case complex.
            test_complex = delete_vertices(case_complex, [vertex])
            report(f"  Vertex selected for deletion: {vertex}")
            report(f"  Homology: {test_complex.homology()}")
        report("")


if __name__ == "__main__":
    facets_file = os.environ.get("FACETS_FILE")
    if not facets_file:
        raise SystemExit("Set FACETS_FILE to the path of your facets file.")

    ORIGINAL_SIMPLICIAL = SimplicialComplex(load_facets_from_file(facets_file))
    with POTENTIAL_CASES_FILE.open() as f:
        potential_cases = json.load(f)

    output_dir = Path("outputs")
    output_dir.mkdir(parents=True, exist_ok=True)
    name = POTENTIAL_CASES_FILE.stem.removesuffix("_potential_cases")
    output_file = output_dir / f"{name}_remaining_homology.txt"
    with output_file.open("w") as output:
        def report(line):
            print(line, flush=True)
            print(line, file=output)

        report(f"Facets file: {facets_file}")
        report(f"Potential cases file: {POTENTIAL_CASES_FILE}")
        report(f"Potential cases: {len(potential_cases)}")
        report("Homology below is reduced homology after the selected deletion.")
        report("")
        report_remaining_homology(ORIGINAL_SIMPLICIAL, potential_cases, report)

    print(f"Saved homology report to: {output_file}", flush=True)
