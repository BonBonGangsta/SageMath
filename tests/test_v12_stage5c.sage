"""Exhaustive small-complex tests for Stage 5C automorphism orbits."""

import itertools
import sys
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR / "scripts"))

from simplicial_bitset import normalize_facet_masks, vertices_mask  # noqa: E402
from simplicial_isomorphism import automorphism_vertex_orbits  # noqa: E402


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


def relabel_facets(facet_masks, present_positions, permutation):
    position_to_compact = {
        position: index for index, position in enumerate(present_positions)
    }
    return tuple(
        sorted(
            tuple(
                sorted(
                    permutation[position_to_compact[position]]
                    for position in present_positions
                    if facet_mask & (1 << position)
                )
            )
            for facet_mask in facet_masks
        )
    )


def brute_force_orbits(facet_masks, vertex_count):
    normalized = normalize_facet_masks(facet_masks)
    present_mask = vertices_mask(normalized)
    present_positions = tuple(
        position
        for position in range(vertex_count)
        if present_mask & (1 << position)
    )
    identity_facets = relabel_facets(
        normalized,
        present_positions,
        tuple(range(len(present_positions))),
    )
    automorphisms = [
        permutation
        for permutation in itertools.permutations(
            range(len(present_positions))
        )
        if relabel_facets(
            normalized, present_positions, permutation
        ) == identity_facets
    ]
    unseen = set(range(len(present_positions)))
    orbits = set()
    while unseen:
        representative = min(unseen)
        orbit = frozenset(
            permutation[representative] for permutation in automorphisms
        )
        orbits.add(
            frozenset(present_positions[index] for index in orbit)
        )
        unseen -= orbit
    return (present_positions, orbits)


def mapped_facets(facet_masks, vertex_order, mapping):
    return tuple(
        sorted(
            tuple(
                sorted(
                    mapping[vertex_order[position]]
                    for position in range(len(vertex_order))
                    if facet_mask & (1 << position)
                )
            )
            for facet_mask in facet_masks
        )
    )


complex_count = 0
map_count = 0
for vertex_count in range(1, 5):
    vertex_order = tuple(range(vertex_count))
    for facet_masks in all_distinct_complexes(vertex_count):
        present_positions, expected_orbits = (
            brute_force_orbits(facet_masks, vertex_count)
        )
        identity_facets = mapped_facets(
            facet_masks,
            vertex_order,
            {position: position for position in present_positions},
        )
        candidate_order = tuple(reversed(present_positions))
        records = automorphism_vertex_orbits(
            facet_masks,
            vertex_order,
            candidate_vertices=candidate_order,
        )
        actual_orbits = {
            frozenset(record["members"]) for record in records
        }
        assert actual_orbits == expected_orbits

        for record in records:
            expected_representative = next(
                vertex
                for vertex in candidate_order
                if vertex in record["members"]
            )
            assert record["representative"] == expected_representative
            assert set(record["automorphisms"]) == set(record["members"])
            for member, serialized_mapping in record[
                "automorphisms"
            ].items():
                mapping = dict(serialized_mapping)
                assert set(mapping) == set(present_positions)
                assert set(mapping.values()) == set(present_positions)
                assert mapping[record["representative"]] == member
                assert mapped_facets(
                    facet_masks, vertex_order, mapping
                ) == identity_facets
                map_count += 1
        complex_count += 1

# Without colors the path endpoints form one orbit. Distinguishing one endpoint
# splits that orbit, exactly as strict protected-vertex search requires.
path_facets = (0b011, 0b110)
plain = automorphism_vertex_orbits(
    path_facets, (10, 20, 30), candidate_vertices=(10, 20, 30)
)
assert {frozenset(record["members"]) for record in plain} == {
    frozenset({10, 30}),
    frozenset({20}),
}
colored = automorphism_vertex_orbits(
    path_facets,
    (10, 20, 30),
    candidate_vertices=(20, 30),
    distinguished_vertices=(10,),
)
assert {frozenset(record["members"]) for record in colored} == {
    frozenset({20}),
    frozenset({30}),
}

try:
    automorphism_vertex_orbits(
        path_facets,
        (10, 20, 30),
        candidate_vertices=(10, 20),
    )
except ValueError:
    pass
else:
    raise AssertionError("partial uncolored orbit was accepted")

print(
    "PASS: automorphism orbits matched independent brute force across "
    f"{complex_count} labeled complexes and {map_count} explicit maps."
)
print("PASS: colored candidate coverage was enforced.")
print("All Stage 5C automorphism tests passed.")
