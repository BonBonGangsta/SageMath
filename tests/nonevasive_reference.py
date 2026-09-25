"""Small independent reference implementation of non-evasiveness.

This intentionally uses immutable Python sets and the recursive definition.
It does not import the v12 bitset engine, caches, heuristics, or certificates.
The implementation is exponential and is only intended for tiny regression
complexes.
"""

from functools import lru_cache


def normalize_facets(facets):
    """Return unique inclusion-maximal facets in a stable representation."""
    unique = {frozenset(facet) for facet in facets}
    if not unique:
        return tuple()
    maximal = [
        facet
        for facet in unique
        if not any(facet < candidate for candidate in unique)
    ]
    return tuple(
        sorted(maximal, key=lambda facet: (len(facet), tuple(sorted(facet))))
    )


def vertices_of(facets):
    vertices = set()
    for facet in facets:
        vertices.update(facet)
    return frozenset(vertices)


def deletion(facets, vertex):
    return normalize_facets(facet - {vertex} for facet in facets)


def link(facets, vertex):
    return normalize_facets(
        facet - {vertex} for facet in facets if vertex in facet
    )


@lru_cache(maxsize=None)
def _is_nonevasive(normalized_facets):
    vertices = vertices_of(normalized_facets)
    if not vertices:
        return False
    if (
        len(normalized_facets) == 1
        and normalized_facets[0] == vertices
    ):
        return True
    for vertex in sorted(vertices):
        if _is_nonevasive(link(normalized_facets, vertex)) and _is_nonevasive(
            deletion(normalized_facets, vertex)
        ):
            return True
    return False


def is_nonevasive(facets):
    """Return the exact recursive verdict for one small finite complex."""
    return _is_nonevasive(normalize_facets(facets))


def clear_cache():
    _is_nonevasive.cache_clear()
