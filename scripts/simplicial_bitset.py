"""Bitset operations for finite simplicial complexes.

The exact v12 search identifies a state by the root vertices that have been
linked or deleted.  This module reconstructs the facets of such a state using
Python integer masks, without constructing intermediate SageMath complexes.

Zero is retained as the empty facet when it is the only facet.  This matches
the representation used by Sage for a complex with no vertices.
"""

import operator


def _as_integer(value, name):
    if isinstance(value, bool):
        raise TypeError(f"{name} must be an integer")
    try:
        return operator.index(value)
    except TypeError as exc:
        raise TypeError(f"{name} must be an integer") from exc


def _as_nonnegative_int(value, name):
    value = _as_integer(value, name)
    if value < 0:
        raise ValueError(f"{name} cannot be negative")
    return value


def _as_vertex_bit(value):
    bit = _as_nonnegative_int(value, "vertex bit")
    if bit == 0 or bit & (bit - 1):
        raise ValueError("vertex bit must contain exactly one bit")
    return bit


def normalize_facet_masks(facet_masks):
    """Return unique, inclusion-maximal facet masks in canonical order."""
    unique_masks = {
        _as_nonnegative_int(mask, "facet mask") for mask in facet_masks
    }
    if not unique_masks:
        return tuple()

    maximal_masks = []
    for mask in sorted(
        unique_masks,
        key=lambda value: (value.bit_count(), value),
        reverse=True,
    ):
        if not any(mask & existing == mask for existing in maximal_masks):
            maximal_masks.append(mask)

    return tuple(
        sorted(maximal_masks, key=lambda value: (value.bit_count(), value))
    )


def vertices_mask(facet_masks):
    """Return the union of all vertices present in ``facet_masks``."""
    result = 0
    for mask in facet_masks:
        result |= _as_nonnegative_int(mask, "facet mask")
    return result


def delete_vertex_from_facets(facet_masks, vertex_bit):
    """Return maximal facets after deleting one vertex."""
    bit = _as_vertex_bit(vertex_bit)
    return normalize_facet_masks(
        _as_nonnegative_int(mask, "facet mask") & ~bit
        for mask in facet_masks
    )


def link_vertex_from_facets(facet_masks, vertex_bit):
    """Return maximal facets of the link at one present vertex."""
    bit = _as_vertex_bit(vertex_bit)
    containing_facets = []
    for mask in facet_masks:
        mask = _as_nonnegative_int(mask, "facet mask")
        if mask & bit:
            containing_facets.append(mask ^ bit)
    if not containing_facets:
        raise ValueError("cannot take the link of an absent vertex")
    return normalize_facet_masks(containing_facets)


class RootBitsetComplex:
    """A fixed root complex with direct linked/deleted state operations."""

    def __init__(self, facets, vertex_order=None):
        facet_lists = [
            tuple(
                _as_integer(vertex, "root vertex label")
                for vertex in facet
            )
            for facet in facets
        ]
        if not facet_lists:
            raise ValueError("at least one root facet is required")

        root_vertices = set()
        for index, facet in enumerate(facet_lists, start=1):
            if len(set(facet)) != len(facet):
                raise ValueError(f"root facet {index} repeats a vertex")
            root_vertices.update(facet)

        if vertex_order is None:
            order = tuple(sorted(root_vertices))
        else:
            order = tuple(
                _as_integer(vertex, "vertex_order label")
                for vertex in vertex_order
            )
            if len(set(order)) != len(order):
                raise ValueError("vertex_order repeats a vertex")
            if set(order) != root_vertices:
                raise ValueError(
                    "vertex_order must contain exactly the root vertices"
                )

        self.vertex_order = order
        self.vertex_bits = {
            vertex: 1 << index for index, vertex in enumerate(order)
        }
        self.all_vertices_mask = (1 << len(order)) - 1
        self.root_facets = normalize_facet_masks(
            self.mask_for_vertices(facet) for facet in facet_lists
        )

    def mask_for_vertices(self, vertices):
        """Encode a collection of root vertex labels as one mask."""
        result = 0
        for vertex in vertices:
            try:
                bit = self.vertex_bits[vertex]
            except KeyError as exc:
                raise ValueError(f"unknown root vertex: {vertex}") from exc
            if result & bit:
                raise ValueError(f"vertex collection repeats {vertex}")
            result |= bit
        return result

    def labels_for_mask(self, mask):
        """Decode a mask in the fixed root vertex order."""
        mask = self._validate_known_mask(mask, "mask")
        return tuple(
            vertex
            for index, vertex in enumerate(self.vertex_order)
            if mask & (1 << index)
        )

    def label_facets(self, facet_masks):
        """Decode facet masks into a canonical tuple of label tuples."""
        normalized = normalize_facet_masks(facet_masks)
        decoded = (
            tuple(sorted(self.labels_for_mask(mask))) for mask in normalized
        )
        return tuple(
            sorted(decoded, key=lambda facet: (len(facet), facet))
        )

    def is_root_face(self, face_mask):
        """Return whether a mask is a face of the root complex."""
        face_mask = self._validate_known_mask(face_mask, "face mask")
        return any(
            face_mask & root_facet == face_mask
            for root_facet in self.root_facets
        )

    def state_facets(self, linked_mask=0, deleted_mask=0):
        """Return facets for the state identified by two disjoint masks.

        For every root facet containing the linked face, remove all linked and
        deleted vertices, then retain the inclusion-maximal results.  Links and
        deletions at distinct vertices commute, so no operation history needs
        to be replayed.
        """
        linked_mask = self._validate_known_mask(linked_mask, "linked mask")
        deleted_mask = self._validate_known_mask(deleted_mask, "deleted mask")
        if linked_mask & deleted_mask:
            raise ValueError("linked and deleted masks overlap")
        if not self.is_root_face(linked_mask):
            raise ValueError("linked mask is not a face of the root complex")

        remaining_mask = self.all_vertices_mask & ~(
            linked_mask | deleted_mask
        )
        return normalize_facet_masks(
            root_facet & remaining_mask
            for root_facet in self.root_facets
            if root_facet & linked_mask == linked_mask
        )

    def sage_complex(self, facet_masks):
        """Materialize a Sage complex only when a Sage operation is needed."""
        from sage.topology.simplicial_complex import SimplicialComplex

        return SimplicialComplex(
            [list(facet) for facet in self.label_facets(facet_masks)]
        )

    def _validate_known_mask(self, mask, name):
        mask = _as_nonnegative_int(mask, name)
        if mask & ~self.all_vertices_mask:
            raise ValueError(f"{name} contains an unknown root vertex bit")
        return mask
