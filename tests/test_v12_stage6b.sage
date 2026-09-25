"""Low-level tests for Stage 6B obstruction scheduling."""

import ast
import sys
from pathlib import Path

from sage.all import GF
from sage.topology.simplicial_complex import SimplicialComplex


PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR / "scripts"))

from simplicial_bitset import (  # noqa: E402
    RootBitsetComplex,
    facet_complex_has_free_face,
    normalize_facet_masks,
    order_obstruction_names,
)


def all_distinct_complexes(vertex_count):
    nonempty_faces = tuple(range(1, 1 << vertex_count))
    distinct = set()
    for selection in range(1, 1 << len(nonempty_faces)):
        selected = (
            face
            for index, face in enumerate(nonempty_faces)
            if selection & (1 << index)
        )
        distinct.add(normalize_facet_masks(selected))
    return tuple(sorted(distinct))


def sage_has_free_face(complex_):
    facets = [frozenset(facet) for facet in complex_.facets()]
    for facet in facets:
        if len(facet) < 2:
            continue
        for vertex in facet:
            ridge = facet - {vertex}
            if sum(ridge.issubset(other) for other in facets) == 1:
                return True
    return False


def facets_to_labels(facet_masks, labels):
    return [
        [
            labels[position]
            for position in range(len(labels))
            if facet_mask & (1 << position)
        ]
        for facet_mask in facet_masks
    ]


complex_count = 0
for vertex_count in range(1, 5):
    labels = tuple(range(20, 20 + vertex_count))
    for facet_masks in all_distinct_complexes(vertex_count):
        facets = facets_to_labels(facet_masks, labels)
        model = RootBitsetComplex(facets)
        complex_ = SimplicialComplex(facets)
        assert facet_complex_has_free_face(
            model.root_facets
        ) == sage_has_free_face(complex_)
        complex_count += 1

dunce_facets = ast.literal_eval(
    (PROJECT_DIR / "tests/data/dunce_hat.txt").read_text(encoding="utf-8")
)
dunce_model = RootBitsetComplex(dunce_facets)
assert not facet_complex_has_free_face(dunce_model.root_facets)

moore_facets = ast.literal_eval(
    (PROJECT_DIR / "tests/data/moore_space_3.txt").read_text(
        encoding="utf-8"
    )
)
moore = SimplicialComplex(moore_facets)
assert moore.euler_characteristic() == 1
assert all(group.dimension() == 0 for group in moore.homology(
    reduced=True, base_ring=GF(2)
).values())
assert any(group.dimension() > 0 for group in moore.homology(
    reduced=True, base_ring=GF(3)
).values())

names = ("connectivity", "euler_characteristic", "homology_GF2")
profiles = {
    "connectivity": {"calls": 8, "seconds": 8.0, "rejections": 1},
    "euler_characteristic": {
        "calls": 8,
        "seconds": 2.0,
        "rejections": 2,
    },
    "homology_GF2": {"calls": 8, "seconds": 1.0, "rejections": 0},
}
assert order_obstruction_names(names, profiles, mode="fixed") == names
assert order_obstruction_names(
    names, profiles, mode="adaptive", warmup_calls=9
) == names
assert order_obstruction_names(
    names, profiles, mode="adaptive", warmup_calls=8
) == ("euler_characteristic", "connectivity", "homology_GF2")

print(
    "PASS: free-face detection matched Sage across "
    f"{complex_count} labeled complexes"
)
print("PASS: GF(3) detects the Moore-space obstruction missed by GF(2)")
print("PASS: adaptive scheduling respects warmup and measured yield")
print("All Stage 6B low-level tests passed.")
