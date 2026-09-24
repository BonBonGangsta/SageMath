"""Exhaustive Sage equivalence tests for the Stage 4A bitset layer."""

import sys
from pathlib import Path

from sage.topology.simplicial_complex import SimplicialComplex


PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR / "scripts"))

from simplicial_bitset import (  # noqa: E402
    RootBitsetComplex,
    delete_vertex_from_facets,
    link_vertex_from_facets,
    normalize_facet_masks,
    vertices_mask,
)


def canonical_sage_facets(complex_):
    return tuple(
        sorted(
            (
                tuple(sorted(int(vertex) for vertex in facet))
                for facet in complex_.facets()
            ),
            key=lambda facet: (len(facet), facet),
        )
    )


def delete_vertex_sage(complex_, vertex):
    deletion = SimplicialComplex(complex_.facets())
    deletion.remove_faces([[vertex]])
    return SimplicialComplex(deletion.facets())


def reconstruct_with_sage(root, model, linked_mask, deleted_mask):
    state = root
    for index, vertex in enumerate(model.vertex_order):
        bit = 1 << index
        if linked_mask & bit:
            state = state.link([vertex])
    for index, vertex in enumerate(model.vertex_order):
        bit = 1 << index
        if deleted_mask & bit and vertex in state.vertices():
            state = delete_vertex_sage(state, vertex)
    return state


def disjoint_state_masks(vertex_count):
    full_mask = (1 << vertex_count) - 1
    for linked_mask in range(full_mask + 1):
        available = full_mask & ~linked_mask
        deleted_mask = available
        while True:
            yield linked_mask, deleted_mask
            if deleted_mask == 0:
                break
            deleted_mask = (deleted_mask - 1) & available


def compare_model(facets, vertex_order=None):
    model = RootBitsetComplex(facets, vertex_order=vertex_order)
    root = SimplicialComplex(facets)
    expected_root = canonical_sage_facets(root)
    actual_root = model.label_facets(model.root_facets)
    assert actual_root == expected_root, (facets, actual_root, expected_root)

    comparisons = 0
    for linked_mask, deleted_mask in disjoint_state_masks(
        len(model.vertex_order)
    ):
        if not model.is_root_face(linked_mask):
            continue

        bitset_facets = model.state_facets(linked_mask, deleted_mask)
        sage_state = reconstruct_with_sage(
            root, model, linked_mask, deleted_mask
        )
        expected = canonical_sage_facets(sage_state)
        actual = model.label_facets(bitset_facets)
        assert actual == expected, (
            facets,
            linked_mask,
            deleted_mask,
            actual,
            expected,
        )
        assert canonical_sage_facets(
            model.sage_complex(bitset_facets)
        ) == expected
        comparisons += 1

        present_mask = vertices_mask(bitset_facets)
        for index, vertex in enumerate(model.vertex_order):
            vertex_bit = 1 << index
            if not present_mask & vertex_bit:
                continue

            actual_link = model.label_facets(
                link_vertex_from_facets(bitset_facets, vertex_bit)
            )
            expected_link = canonical_sage_facets(sage_state.link([vertex]))
            assert actual_link == expected_link

            actual_deletion = model.label_facets(
                delete_vertex_from_facets(bitset_facets, vertex_bit)
            )
            expected_deletion = canonical_sage_facets(
                delete_vertex_sage(sage_state, vertex)
            )
            assert actual_deletion == expected_deletion

    return comparisons


def all_distinct_complexes(vertex_count):
    """Generate every nonempty antichain of nonempty faces."""
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


def mask_facets_to_labels(facet_masks, labels):
    return [
        [
            labels[index]
            for index in range(len(labels))
            if facet_mask & (1 << index)
        ]
        for facet_mask in facet_masks
    ]


def assert_raises(exception_type, operation):
    try:
        operation()
    except exception_type:
        return
    raise AssertionError(f"Expected {exception_type.__name__}")


assert normalize_facet_masks([0, 1, 1, 3, 2]) == (3,)
assert normalize_facet_masks([0]) == (0,)
assert_raises(TypeError, lambda: normalize_facet_masks([1.5]))
assert_raises(ValueError, lambda: normalize_facet_masks([-1]))
assert_raises(ValueError, lambda: delete_vertex_from_facets((1,), 3))
assert_raises(ValueError, lambda: link_vertex_from_facets((1,), 2))

special_cases = [
    ([[10, 20, 30]], [30, 10, 20]),
    ([[10, 20], [20, 30], [30, 40]], [40, 20, 10, 30]),
    ([[1, 2, 3], [1, 4], [4, 5], [1, 2]], None),
    ([[-7, 0], [0, 11], [11, 23], [-7, 23]], [23, -7, 11, 0]),
]

state_comparisons = 0
complex_count = 0
for facets, vertex_order in special_cases:
    state_comparisons += compare_model(facets, vertex_order=vertex_order)
    complex_count += 1

for vertex_count in range(1, 5):
    labels = tuple(range(1, vertex_count + 1))
    for facet_masks in all_distinct_complexes(vertex_count):
        facets = mask_facets_to_labels(facet_masks, labels)
        state_comparisons += compare_model(facets)
        complex_count += 1

validation_model = RootBitsetComplex([[1, 2], [2, 3]])
assert_raises(
    ValueError,
    lambda: validation_model.state_facets(1, 1),
)
assert_raises(
    ValueError,
    lambda: validation_model.state_facets(1 << 10, 0),
)
nonface_mask = validation_model.mask_for_vertices([1, 3])
assert_raises(
    ValueError,
    lambda: validation_model.state_facets(nonface_mask, 0),
)

print(
    "PASS: bitset deletion, link, and direct state reconstruction matched "
    f"Sage across {complex_count} complexes and "
    f"{state_comparisons} valid states."
)
print("All Stage 4A tests passed.")
