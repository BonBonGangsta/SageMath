"""Exact isomorphism keys for finite simplicial complexes.

The vertex-facet incidence graph is canonically labeled with two color
classes: simplicial vertices and facets.  Keeping those classes separate is
essential because an ordinary graph isomorphism could otherwise exchange a
vertex-node with a facet-node of the same degree.

No digest is used.  The returned key contains the complete edge set of the
canonically labeled incidence graph together with both color-class sizes.
"""

from sage.all import Graph

from simplicial_bitset import normalize_facet_masks, vertices_mask


def canonical_incidence_key(
    facet_masks,
    vertex_order,
    distinguished_vertices=(),
):
    """Return an exact isomorphism key and a label-to-canonical map.

    ``facet_masks`` uses bit positions from ``vertex_order``.  Only vertices
    present in the normalized facets participate in the incidence graph.
    The map in the return value sends each present root vertex label to its
    canonical incidence-graph label.
    """
    order = tuple(vertex_order)
    if len(set(order)) != len(order):
        raise ValueError("vertex_order repeats a vertex")

    normalized_facets = normalize_facet_masks(facet_masks)
    known_mask = (1 << len(order)) - 1
    if any(mask & ~known_mask for mask in normalized_facets):
        raise ValueError("facet mask contains an unknown vertex bit")

    present_mask = vertices_mask(normalized_facets)
    present_positions = tuple(
        index
        for index in range(len(order))
        if present_mask & (1 << index)
    )
    distinguished = {int(vertex) for vertex in distinguished_vertices}
    unknown_distinguished = distinguished - set(order)
    if unknown_distinguished:
        raise ValueError("distinguished_vertices contains an unknown label")

    ordinary_vertex_nodes = [
        ("vertex", index)
        for index in present_positions
        if order[index] not in distinguished
    ]
    distinguished_vertex_nodes = [
        ("vertex", index)
        for index in present_positions
        if order[index] in distinguished
    ]
    vertex_nodes = ordinary_vertex_nodes + distinguished_vertex_nodes
    facet_nodes = [
        ("facet", index) for index in range(len(normalized_facets))
    ]

    incidence_graph = Graph()
    incidence_graph.add_vertices(vertex_nodes)
    incidence_graph.add_vertices(facet_nodes)
    incidence_graph.add_edges(
        (("vertex", position), ("facet", facet_index))
        for facet_index, facet_mask in enumerate(normalized_facets)
        for position in present_positions
        if facet_mask & (1 << position)
    )

    # Sage does not accept empty cells in a partition.  Retain the cell sizes
    # in the key below so an absent color class still remains distinguishable.
    partition = [
        cell
        for cell in (
            ordinary_vertex_nodes,
            distinguished_vertex_nodes,
            facet_nodes,
        )
        if cell
    ]
    canonical_graph, certificate = incidence_graph.canonical_label(
        partition=partition,
        algorithm="sage",
        certificate=True,
    )

    canonical_edges = tuple(
        (int(source), int(target))
        for source, target in canonical_graph.edges(
            sort=True, labels=False
        )
    )
    key = (
        (
            len(ordinary_vertex_nodes),
            len(distinguished_vertex_nodes),
        ),
        len(facet_nodes),
        canonical_edges,
    )
    label_to_canonical = {
        int(order[position]): int(certificate[("vertex", position)])
        for position in present_positions
    }
    return (key, label_to_canonical)


def canonical_map_inverse(label_to_canonical):
    """Invert a bijective label-to-canonical mapping."""
    inverse = {}
    for label, canonical_label in label_to_canonical.items():
        label = int(label)
        canonical_label = int(canonical_label)
        if canonical_label in inverse:
            raise ValueError("canonical vertex mapping is not injective")
        inverse[canonical_label] = label
    return inverse


def vertex_isomorphism(
    source_label_to_canonical,
    target_canonical_to_label,
):
    """Return the label bijection induced through one canonical form."""
    if set(source_label_to_canonical.values()) != set(
        target_canonical_to_label
    ):
        raise ValueError("canonical vertex mappings do not cover the same set")

    return tuple(
        sorted(
            (
                int(source_label),
                int(target_canonical_to_label[canonical_label]),
            )
            for source_label, canonical_label
            in source_label_to_canonical.items()
        )
    )
