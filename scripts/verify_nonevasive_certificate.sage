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
    elif reason == "nontrivial_homology_ZZ":
        valid = has_nontrivial_reduced_homology(K, ZZ, "ZZ")
    elif reason == "nontrivial_homology_GF2":
        valid = has_nontrivial_reduced_homology(K, GF(2), "GF2")
    else:
        raise VerificationError(f"Unknown negative terminal reason: {reason}")
    if not valid:
        raise VerificationError(f"Terminal claim is false: {reason}")


def verify_certificate(facets_path, certificate_path):
    root = SimplicialComplex(load_facets(facets_path))
    with Path(certificate_path).open(encoding="utf-8") as certificate_file:
        document = json.load(certificate_file)

    if document.get("format") != "simplicial_nonevasiveness_certificate":
        raise VerificationError("Unknown certificate format")
    if document.get("schema_version") != 1:
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

        terminal_reason = record.get("terminal_reason")
        if terminal_reason is not None:
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
            failures_by_vertex = {}
            for failure in failed_children:
                if not isinstance(failure, dict):
                    raise VerificationError("Malformed failed-child record")
                vertex = failure.get("vertex")
                branch = failure.get("branch")
                if type(vertex) is not int or vertex not in current_vertices:
                    raise VerificationError("Invalid failed-child vertex")
                if vertex in failures_by_vertex:
                    raise VerificationError(
                        f"Vertex {vertex} is repeated in an evasive state"
                    )
                if branch not in {"deletion", "link"}:
                    raise VerificationError("Invalid failed-child branch")
                failures_by_vertex[vertex] = failure

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

            if set(failures_by_vertex) != current_vertices:
                missing = sorted(current_vertices - set(failures_by_vertex))
                extra = sorted(set(failures_by_vertex) - current_vertices)
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
