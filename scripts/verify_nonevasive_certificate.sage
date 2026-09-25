"""Independently verify a v12 non-evasiveness or evasiveness certificate.

Usage:
    sage scripts/verify_nonevasive_certificate.sage FACETS CERTIFICATE
"""

import argparse
import ast
import hashlib
import json
from pathlib import Path

from sage.all import GF, ZZ
from sage.topology.simplicial_complex import SimplicialComplex


class VerificationError(Exception):
    pass


def load_facets(path):
    text = Path(path).read_text(encoding="utf-8")
    try:
        facets = json.loads(text)
    except json.JSONDecodeError:
        facets = ast.literal_eval(text)
    if not isinstance(facets, (list, tuple)) or not facets:
        raise VerificationError("The facets file must contain a nonempty list")
    normalized = []
    for index, facet in enumerate(facets, start=1):
        if not isinstance(facet, (list, tuple)) or not facet:
            raise VerificationError(f"Facet {index} is not a nonempty list")
        if any(type(vertex) is not int for vertex in facet):
            raise VerificationError(f"Facet {index} has a non-integer vertex")
        if len(set(facet)) != len(facet):
            raise VerificationError(f"Facet {index} repeats a vertex")
        normalized.append(list(facet))
    return normalized


def delete_vertex(K, vertex):
    deletion = SimplicialComplex(K.facets())
    deletion.remove_faces([[vertex]])
    return SimplicialComplex(deletion.facets())


def canonical_facets(K):
    return sorted(
        (sorted(int(vertex) for vertex in facet) for facet in K.facets()),
        key=lambda facet: (len(facet), facet),
    )


def canonical_complex_sha256(K):
    encoded = json.dumps(
        canonical_facets(K), separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def is_simplex(K):
    vertices = set(K.vertices())
    facets = list(K.facets())
    return (
        bool(vertices)
        and len(facets) == 1
        and set(facets[0]) == vertices
    )


def is_tree_complex(K):
    return K.dimension() == 1 and K.graph().is_tree()


def has_free_face(K):
    """Return whether a codimension-one face has one maximal cofacet."""
    facets = [frozenset(facet) for facet in K.facets()]
    for facet in facets:
        if len(facet) < 2:
            continue
        for vertex in facet:
            ridge = facet - {vertex}
            containing_facets = sum(
                ridge.issubset(candidate) for candidate in facets
            )
            if containing_facets == 1:
                return True
    return False


def is_small_prime(value):
    if value < 2 or value > 97:
        return False
    divisor = 2
    while divisor * divisor <= value:
        if value % divisor == 0:
            return False
        divisor += 1
    return True


def parse_mask(value, field_name):
    if not isinstance(value, str):
        raise VerificationError(f"{field_name} must be a hexadecimal string")
    try:
        mask = int(value, 0)
    except ValueError as exc:
        raise VerificationError(f"Invalid {field_name}: {value}") from exc
    if mask < 0:
        raise VerificationError(f"{field_name} cannot be negative")
    return mask


def state_id(linked_mask, deleted_mask):
    return f"L{linked_mask:x}-D{deleted_mask:x}"


def reconstruct_state(root, linked_mask, deleted_mask, vertex_order):
    if linked_mask & deleted_mask:
        raise VerificationError("Linked and deleted masks overlap")
    if (linked_mask | deleted_mask) >> len(vertex_order):
        raise VerificationError("A state mask contains an unknown vertex bit")

    state = root
    for index, vertex in enumerate(vertex_order):
        if linked_mask & (1 << index):
            if vertex not in state.vertices():
                raise VerificationError(
                    f"Cannot take link at absent vertex {vertex}"
                )
            state = state.link([vertex])
    for index, vertex in enumerate(vertex_order):
        if deleted_mask & (1 << index) and vertex in state.vertices():
            state = delete_vertex(state, vertex)
    return state


def verify_success_terminal(K, reason):
    if reason == "simplex":
        valid = is_simplex(K)
    elif reason == "cone":
        valid = bool(K.cone_vertices())
    elif reason == "tree":
        valid = is_tree_complex(K)
    else:
        raise VerificationError(f"Unknown positive terminal reason: {reason}")
    if not valid:
        raise VerificationError(f"Terminal claim is false: {reason}")


def homology_group_is_trivial(group, ring_name):
    if ring_name == "ZZ":
        return len(group.invariants()) == 0
    return int(group.dimension()) == 0


def has_nontrivial_reduced_homology(K, base_ring, ring_name):
    homology = K.homology(reduced=True, base_ring=base_ring)
    return any(
        not homology_group_is_trivial(group, ring_name)
        for group in homology.values()
    )


def verify_failure_terminal(K, reason):
    if reason == "empty_complex":
        valid = not K.vertices()
    elif reason == "one_dimensional_not_tree":
        valid = K.dimension() == 1 and not is_tree_complex(K)
    elif reason == "disconnected":
        valid = bool(K.vertices()) and not K.is_connected()
    elif reason == "euler_characteristic_not_one":
        valid = K.euler_characteristic() != 1
    elif reason == "no_free_face_noncollapsible":
        valid = (
            bool(K.vertices())
            and not is_simplex(K)
            and not has_free_face(K)
        )
    elif reason == "nontrivial_homology_ZZ":
        valid = has_nontrivial_reduced_homology(K, ZZ, "ZZ")
    elif reason.startswith("nontrivial_homology_GF"):
        prime_text = reason.removeprefix("nontrivial_homology_GF")
        if not prime_text.isdigit() or not is_small_prime(int(prime_text)):
            raise VerificationError(
                f"Invalid finite-field terminal reason: {reason}"
            )
        prime = int(prime_text)
        valid = has_nontrivial_reduced_homology(
            K, GF(prime), f"GF{prime}"
        )
    else:
        raise VerificationError(f"Unknown negative terminal reason: {reason}")
    if not valid:
        raise VerificationError(f"Terminal claim is false: {reason}")


def verify_vertex_isomorphism(source_K, target_K, serialized_mapping):
    if not isinstance(serialized_mapping, list):
        raise VerificationError("Vertex isomorphism must be a list")

    mapping = {}
    target_vertices_seen = set()
    for entry in serialized_mapping:
        if not isinstance(entry, dict) or set(entry) != {
            "source_vertex",
            "target_vertex",
        }:
            raise VerificationError("Malformed vertex-isomorphism entry")
        source_vertex = entry["source_vertex"]
        target_vertex = entry["target_vertex"]
        if type(source_vertex) is not int or type(target_vertex) is not int:
            raise VerificationError(
                "Vertex-isomorphism labels must be integers"
            )
        if source_vertex in mapping:
            raise VerificationError(
                "Vertex isomorphism repeats a source vertex"
            )
        if target_vertex in target_vertices_seen:
            raise VerificationError(
                "Vertex isomorphism repeats a target vertex"
            )
        mapping[source_vertex] = target_vertex
        target_vertices_seen.add(target_vertex)

    source_vertices = {int(vertex) for vertex in source_K.vertices()}
    target_vertices = {int(vertex) for vertex in target_K.vertices()}
    if set(mapping) != source_vertices:
        raise VerificationError(
            "Vertex isomorphism does not cover the source vertices"
        )
    if target_vertices_seen != target_vertices:
        raise VerificationError(
            "Vertex isomorphism does not cover the target vertices"
        )

    mapped_facets = sorted(
        (
            sorted(mapping[int(vertex)] for vertex in facet)
            for facet in source_K.facets()
        ),
        key=lambda facet: (len(facet), facet),
    )
    if mapped_facets != canonical_facets(target_K):
        raise VerificationError(
            "Vertex mapping is not a simplicial isomorphism"
        )
    return mapping


def verify_certificate(facets_path, certificate_path):
    root = SimplicialComplex(load_facets(facets_path))
    with Path(certificate_path).open(encoding="utf-8") as certificate_file:
        document = json.load(certificate_file)

    if document.get("format") != "simplicial_nonevasiveness_certificate":
        raise VerificationError("Unknown certificate format")
    schema_version = document.get("schema_version")
    if schema_version not in {1, 2, 3, 4}:
        raise VerificationError("Unsupported certificate schema version")
    certificate_kind = document.get("certificate_kind")
    expected_results = {
        "non_evasive": "NON_EVASIVE",
        "evasive": "EVASIVE_CERTIFIED",
    }
    if certificate_kind not in expected_results:
        raise VerificationError("Unknown certificate kind")
    expected_root_verdict = expected_results[certificate_kind]
    if document.get("result") != expected_root_verdict:
        raise VerificationError("Certificate kind and result disagree")

    input_record = document.get("input")
    if not isinstance(input_record, dict):
        raise VerificationError("Certificate input metadata is missing")
    if input_record.get("canonical_facets_sha256") != canonical_complex_sha256(root):
        raise VerificationError("The certificate input hash does not match")

    vertex_order = input_record.get("vertex_order")
    if (
        not isinstance(vertex_order, list)
        or any(type(vertex) is not int for vertex in vertex_order)
        or len(set(vertex_order)) != len(vertex_order)
        or set(vertex_order) != {int(vertex) for vertex in root.vertices()}
    ):
        raise VerificationError("Certificate vertex order does not match the input")
    vertex_bits = {
        vertex: 1 << index for index, vertex in enumerate(vertex_order)
    }

    serialized_states = document.get("states")
    if not isinstance(serialized_states, list) or not serialized_states:
        raise VerificationError("Certificate contains no states")
    states = {}
    for record in serialized_states:
        if not isinstance(record, dict) or not isinstance(record.get("id"), str):
            raise VerificationError("Malformed state record")
        identifier = record["id"]
        if identifier in states:
            raise VerificationError(f"Duplicate state ID: {identifier}")
        linked_mask = parse_mask(record.get("linked_mask"), "linked_mask")
        deleted_mask = parse_mask(record.get("deleted_mask"), "deleted_mask")
        if identifier != state_id(linked_mask, deleted_mask):
            raise VerificationError(f"State ID does not match masks: {identifier}")
        record["_state_key"] = (linked_mask, deleted_mask)
        states[identifier] = record

    root_id = document.get("root_state")
    if root_id != state_id(0, 0) or root_id not in states:
        raise VerificationError("The root state is missing or invalid")

    verified = set()
    active = set()

    def verify_state(identifier, expected_verdict):
        if identifier not in states:
            raise VerificationError(f"Referenced state is missing: {identifier}")
        record = states[identifier]
        if record.get("verdict") != expected_verdict:
            raise VerificationError(
                f"State {identifier} has the wrong child verdict"
            )
        if identifier in verified:
            return
        if identifier in active:
            raise VerificationError("Certificate state graph contains a cycle")
        active.add(identifier)
        linked_mask, deleted_mask = record["_state_key"]
        K = reconstruct_state(
            root, linked_mask, deleted_mask, vertex_order
        )

        equivalent_state = record.get("equivalent_state")
        isomorphic_state = record.get("isomorphic_state")
        terminal_reason = record.get("terminal_reason")
        if ("isomorphic_state" in record) != (
            "vertex_isomorphism" in record
        ):
            raise VerificationError(
                "Isomorphism record requires both target and vertex mapping"
            )
        if equivalent_state is not None:
            if schema_version < 2:
                raise VerificationError(
                    "Equivalence records require certificate schema 2"
                )
            if not isinstance(equivalent_state, str):
                raise VerificationError(
                    "Equivalent state must be a state identifier"
                )
            conflicting_fields = {
                "terminal_reason",
                "winning_vertex",
                "deletion_child",
                "link_child",
                "failed_children",
                "isomorphic_state",
                "vertex_isomorphism",
            } & set(record)
            if conflicting_fields:
                raise VerificationError(
                    "Equivalence record contains another proof form"
                )
            verify_state(equivalent_state, expected_verdict)
            target_record = states[equivalent_state]
            target_K = reconstruct_state(
                root, *target_record["_state_key"], vertex_order
            )
            if canonical_facets(K) != canonical_facets(target_K):
                raise VerificationError(
                    "Equivalent states do not have identical facets"
                )
        elif "isomorphic_state" in record:
            if schema_version < 3:
                raise VerificationError(
                    "Isomorphism records require certificate schema 3"
                )
            if not isinstance(isomorphic_state, str):
                raise VerificationError(
                    "Isomorphic state must be a state identifier"
                )
            conflicting_fields = {
                "equivalent_state",
                "terminal_reason",
                "winning_vertex",
                "deletion_child",
                "link_child",
                "failed_children",
            } & set(record)
            if conflicting_fields:
                raise VerificationError(
                    "Isomorphism record contains another proof form"
                )
            verify_state(isomorphic_state, expected_verdict)
            target_record = states[isomorphic_state]
            target_K = reconstruct_state(
                root, *target_record["_state_key"], vertex_order
            )
            verify_vertex_isomorphism(
                K,
                target_K,
                record.get("vertex_isomorphism"),
            )
        elif terminal_reason is not None:
            if expected_verdict == "NON_EVASIVE":
                verify_success_terminal(K, terminal_reason)
            else:
                verify_failure_terminal(K, terminal_reason)
        elif expected_verdict == "NON_EVASIVE":
            winning_vertex = record.get("winning_vertex")
            if type(winning_vertex) is not int or winning_vertex not in K.vertices():
                raise VerificationError(
                    f"Invalid winning vertex at state {identifier}"
                )
            vertex_bit = vertex_bits[winning_vertex]
            if (linked_mask | deleted_mask) & vertex_bit:
                raise VerificationError("Winning vertex was already decided")

            expected_deletion = state_id(
                linked_mask, deleted_mask | vertex_bit
            )
            expected_link = state_id(
                linked_mask | vertex_bit, deleted_mask
            )
            if record.get("deletion_child") != expected_deletion:
                raise VerificationError("Incorrect deletion child state")
            if record.get("link_child") != expected_link:
                raise VerificationError("Incorrect link child state")

            verify_state(expected_deletion, "NON_EVASIVE")
            verify_state(expected_link, "NON_EVASIVE")

            deletion_record = states[expected_deletion]
            link_record = states[expected_link]
            deletion_K = reconstruct_state(
                root, *deletion_record["_state_key"], vertex_order
            )
            link_K = reconstruct_state(
                root, *link_record["_state_key"], vertex_order
            )
            if canonical_facets(deletion_K) != canonical_facets(
                delete_vertex(K, winning_vertex)
            ):
                raise VerificationError("Deletion transition is incorrect")
            if canonical_facets(link_K) != canonical_facets(
                K.link([winning_vertex])
            ):
                raise VerificationError("Link transition is incorrect")
        else:
            failed_children = record.get("failed_children")
            if not isinstance(failed_children, list):
                raise VerificationError(
                    f"Evasive state lacks failed children: {identifier}"
                )
            current_vertices = {int(vertex) for vertex in K.vertices()}
            covered_vertices = set()
            for failure in failed_children:
                if not isinstance(failure, dict):
                    raise VerificationError("Malformed failed-child record")
                vertex = failure.get("vertex")
                branch = failure.get("branch")
                if type(vertex) is not int or vertex not in current_vertices:
                    raise VerificationError("Invalid failed-child vertex")
                if branch not in {"deletion", "link"}:
                    raise VerificationError("Invalid failed-child branch")

                has_orbit_members = "orbit_members" in failure
                has_orbit_automorphisms = (
                    "orbit_automorphisms" in failure
                )
                if has_orbit_members != has_orbit_automorphisms:
                    raise VerificationError(
                        "Orbit failure requires members and automorphisms"
                    )
                if has_orbit_members:
                    if schema_version < 4:
                        raise VerificationError(
                            "Orbit failures require certificate schema 4"
                        )
                    orbit_members = failure["orbit_members"]
                    if (
                        not isinstance(orbit_members, list)
                        or any(type(member) is not int for member in orbit_members)
                        or len(set(orbit_members)) != len(orbit_members)
                        or vertex not in orbit_members
                        or not set(orbit_members).issubset(current_vertices)
                    ):
                        raise VerificationError("Invalid automorphism orbit")

                    orbit_automorphisms = failure[
                        "orbit_automorphisms"
                    ]
                    if not isinstance(orbit_automorphisms, list):
                        raise VerificationError(
                            "Orbit automorphisms must be a list"
                        )
                    maps_by_target = {}
                    for item in orbit_automorphisms:
                        if not isinstance(item, dict) or set(item) != {
                            "target_vertex",
                            "vertex_isomorphism",
                        }:
                            raise VerificationError(
                                "Malformed orbit-automorphism record"
                            )
                        target_vertex = item["target_vertex"]
                        if (
                            type(target_vertex) is not int
                            or target_vertex in maps_by_target
                            or target_vertex == vertex
                        ):
                            raise VerificationError(
                                "Invalid orbit-automorphism target"
                            )
                        mapping = verify_vertex_isomorphism(
                            K,
                            K,
                            item["vertex_isomorphism"],
                        )
                        if mapping[vertex] != target_vertex:
                            raise VerificationError(
                                "Orbit automorphism does not map its "
                                "representative to the target"
                            )
                        maps_by_target[target_vertex] = mapping

                    expected_targets = set(orbit_members) - {vertex}
                    if set(maps_by_target) != expected_targets:
                        raise VerificationError(
                            "Orbit automorphisms do not justify every member"
                        )
                    covered_by_failure = set(orbit_members)
                else:
                    covered_by_failure = {vertex}

                overlap = covered_vertices & covered_by_failure
                if overlap:
                    raise VerificationError(
                        "Evasive-state vertex coverage overlaps; "
                        f"vertices={sorted(overlap)}"
                    )
                covered_vertices.update(covered_by_failure)

                vertex_bit = vertex_bits[vertex]
                if (linked_mask | deleted_mask) & vertex_bit:
                    raise VerificationError(
                        "Failed-child vertex was already decided"
                    )
                if branch == "deletion":
                    child_key = (
                        linked_mask,
                        deleted_mask | vertex_bit,
                    )
                    expected_K = delete_vertex(K, vertex)
                else:
                    child_key = (
                        linked_mask | vertex_bit,
                        deleted_mask,
                    )
                    expected_K = K.link([vertex])
                child_id = state_id(*child_key)
                if failure.get("child") != child_id:
                    raise VerificationError("Incorrect failed-child state")

                verify_state(child_id, "EVASIVE_CERTIFIED")
                child_record = states[child_id]
                child_K = reconstruct_state(
                    root, *child_record["_state_key"], vertex_order
                )
                if canonical_facets(child_K) != canonical_facets(expected_K):
                    raise VerificationError(
                        f"{branch.capitalize()} transition is incorrect"
                    )

            if covered_vertices != current_vertices:
                missing = sorted(current_vertices - covered_vertices)
                extra = sorted(covered_vertices - current_vertices)
                raise VerificationError(
                    "Evasive state does not cover every vertex; "
                    f"missing={missing}, extra={extra}"
                )

        active.remove(identifier)
        verified.add(identifier)

    verify_state(root_id, expected_root_verdict)
    if verified != set(states):
        raise VerificationError("Certificate contains unreachable state records")
    return (expected_root_verdict, len(verified))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("facets", type=Path)
    parser.add_argument("certificate", type=Path)
    args = parser.parse_args()
    try:
        result, state_count = verify_certificate(args.facets, args.certificate)
    except (OSError, ValueError, VerificationError) as exc:
        raise SystemExit(f"CERTIFICATE_INVALID: {exc}")
    print(f"CERTIFICATE_VALID: {result}; states={state_count}")


if __name__ == "__main__":
    main()
