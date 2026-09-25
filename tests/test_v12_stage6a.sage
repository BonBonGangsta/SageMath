"""Exhaustive tests for Stage 6A cheap child preclassification."""

import sys
from pathlib import Path

from sage.topology.simplicial_complex import SimplicialComplex


PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR / "scripts"))

from simplicial_bitset import (  # noqa: E402
    RootBitsetComplex,
    classify_facets_cheaply,
    facet_complex_is_connected,
    normalize_facet_masks,
)


def all_distinct_complexes(vertex_count):
    nonempty_faces = tuple(range(1, 1 << vertex_count))
    distinct = set()
    for selection in range(1, 1 << len(nonempty_faces)):
        facets = (
            face
            for index, face in enumerate(nonempty_faces)
            if selection & (1 << index)
        )
        distinct.add(normalize_facet_masks(facets))
    return tuple(sorted(distinct))


def expected_sage_classification(complex_):
    vertices = set(complex_.vertices())
    facets = list(complex_.facets())
    if not vertices:
        return (False, "empty_complex")
    if len(facets) == 1 and set(facets[0]) == vertices:
        return (True, "simplex")
    if complex_.cone_vertices():
        return (True, "cone")
    if complex_.dimension() == 1:
        if complex_.graph().is_tree():
            return (True, "tree")
        return (False, "one_dimensional_not_tree")
    if not complex_.is_connected():
        return (False, "disconnected")
    return (None, None)


def facets_to_labels(facet_masks, labels):
    return [
        [
            labels[position]
            for position in range(len(labels))
            if facet_mask & (1 << position)
        ]
        for facet_mask in facet_masks
    ]


assert classify_facets_cheaply((0,)) == (False, "empty_complex")
assert facet_complex_is_connected((0,)) is False

complex_count = 0
classification_counts = {True: 0, False: 0, None: 0}
for vertex_count in range(1, 5):
    labels = tuple(range(10, 10 + vertex_count))
    for facet_masks in all_distinct_complexes(vertex_count):
        facets = facets_to_labels(facet_masks, labels)
        model = RootBitsetComplex(facets)
        complex_ = SimplicialComplex(facets)
        actual = classify_facets_cheaply(model.root_facets)
        expected = expected_sage_classification(complex_)
        assert actual == expected, (facets, actual, expected)
        assert facet_complex_is_connected(model.root_facets) == bool(
            complex_.is_connected()
        )
        classification_counts[actual[0]] += 1
        complex_count += 1

print(
    "PASS: cheap terminal classification matched Sage across "
    f"{complex_count} labeled complexes "
    f"({classification_counts[True]} positive, "
    f"{classification_counts[False]} negative, "
    f"{classification_counts[None]} unresolved)."
)
print("All Stage 6A preclassification tests passed.")
