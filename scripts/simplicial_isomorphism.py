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


def _colored_incidence_graph(
    facet_masks,
    vertex_order,
    distinguished_vertices=(),
):
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
    return (
        order,
        normalized_facets,
        present_positions,
        vertex_nodes,
        facet_nodes,
        incidence_graph,
        partition,
        (
            len(ordinary_vertex_nodes),
            len(distinguished_vertex_nodes),
        ),
    )


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
    (
        order,
        _normalized_facets,
        present_positions,
        _vertex_nodes,
        facet_nodes,
        incidence_graph,
        partition,
        vertex_color_sizes,
    ) = _colored_incidence_graph(
        facet_masks,
        vertex_order,
        distinguished_vertices=distinguished_vertices,
    )
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
        vertex_color_sizes,
        len(facet_nodes),
        canonical_edges,
    )
    label_to_canonical = {
        int(order[position]): int(certificate[("vertex", position)])
        for position in present_positions
    }
    return (key, label_to_canonical)


def automorphism_vertex_orbits(
    facet_masks,
    vertex_order,
    candidate_vertices=None,
    distinguished_vertices=(),
):
    """Return candidate orbits with explicit automorphisms from each rep.

    Orbit representatives follow ``candidate_vertices`` order.  Each returned
    automorphism is a complete source-to-target map on the complex's present
    vertices and sends the orbit representative to its named member.
    """
    (
        order,
        _normalized_facets,
        present_positions,
        vertex_nodes,
        _facet_nodes,
        incidence_graph,
        partition,
        _vertex_color_sizes,
    ) = _colored_incidence_graph(
        facet_masks,
        vertex_order,
        distinguished_vertices=distinguished_vertices,
    )
    present_labels = tuple(int(order[position]) for position in present_positions)
    if candidate_vertices is None:
        candidates = present_labels
    else:
        candidates = tuple(int(vertex) for vertex in candidate_vertices)
    if len(set(candidates)) != len(candidates):
        raise ValueError("candidate_vertices repeats a vertex")
    if not set(candidates).issubset(present_labels):
        raise ValueError("candidate_vertices contains an absent vertex")

    label_to_node = {
        int(order[position]): ("vertex", position)
        for position in present_positions
    }
    node_to_label = {
        node: label for label, node in label_to_node.items()
    }
    graph_nodes = tuple(incidence_graph.vertices(sort=False))
    group = incidence_graph.automorphism_group(
        partition=partition,
        algorithm="sage",
    )
    generators = tuple(group.gens())

    covered = set()
    results = []
    for representative in candidates:
        if representative in covered:
            continue
        representative_node = label_to_node[representative]
        identity = {node: node for node in graph_nodes}
        transport_by_node = {representative_node: identity}
        pending = [representative_node]
        while pending:
            current_node = pending.pop()
            current_transport = transport_by_node[current_node]
            for generator in generators:
                next_node = generator(current_node)
                if next_node in transport_by_node:
                    continue
                transport_by_node[next_node] = {
                    node: generator(image)
                    for node, image in current_transport.items()
                }
                pending.append(next_node)

        orbit_labels = {
            node_to_label[node]
            for node in transport_by_node
            if node in node_to_label
        }
        candidate_orbit = tuple(
            vertex for vertex in candidates if vertex in orbit_labels
        )
        if orbit_labels != set(candidate_orbit):
            raise ValueError(
                "candidate vertices do not contain a complete colored orbit"
            )

        automorphisms = {}
        for member in candidate_orbit:
            transport = transport_by_node[label_to_node[member]]
            automorphisms[member] = tuple(
                sorted(
                    (
                        source_label,
                        node_to_label[transport[source_node]],
                    )
                    for source_label, source_node in label_to_node.items()
                )
            )
        covered.update(candidate_orbit)
        results.append(
            {
                "representative": representative,
                "members": candidate_orbit,
                "automorphisms": automorphisms,
            }
        )

    return tuple(results)


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
