"""Independently verify a v12 non-evasiveness certificate.

Usage:
    sage scripts/verify_nonevasive_certificate.sage FACETS CERTIFICATE
"""

import argparse
import ast
import hashlib
import json
from pathlib import Path

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


def verify_certificate(facets_path, certificate_path):
    root = SimplicialComplex(load_facets(facets_path))
    with Path(certificate_path).open(encoding="utf-8") as certificate_file:
        document = json.load(certificate_file)

    if document.get("format") != "simplicial_nonevasiveness_certificate":
        raise VerificationError("Unknown certificate format")
    if document.get("schema_version") != 1:
        raise VerificationError("Unsupported certificate schema version")
    if document.get("certificate_kind") != "non_evasive":
        raise VerificationError(
            "This verifier stage accepts non-evasive certificates only"
        )
    if document.get("result") != "NON_EVASIVE":
        raise VerificationError("Certificate result is not NON_EVASIVE")

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

    def verify_state(identifier):
        if identifier in verified:
            return
        if identifier in active:
            raise VerificationError("Certificate state graph contains a cycle")
        if identifier not in states:
            raise VerificationError(f"Referenced state is missing: {identifier}")
        active.add(identifier)
        record = states[identifier]
        if record.get("verdict") != "NON_EVASIVE":
            raise VerificationError(
                f"Positive proof references a non-success state: {identifier}"
            )
        linked_mask, deleted_mask = record["_state_key"]
        K = reconstruct_state(
            root, linked_mask, deleted_mask, vertex_order
        )

        terminal_reason = record.get("terminal_reason")
        if terminal_reason is not None:
            verify_success_terminal(K, terminal_reason)
        else:
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

            verify_state(expected_deletion)
            verify_state(expected_link)

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

        active.remove(identifier)
        verified.add(identifier)

    verify_state(root_id)
    if verified != set(states):
        raise VerificationError("Certificate contains unreachable state records")
    return len(verified)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("facets", type=Path)
    parser.add_argument("certificate", type=Path)
    args = parser.parse_args()
    try:
        state_count = verify_certificate(args.facets, args.certificate)
    except (OSError, ValueError, VerificationError) as exc:
        raise SystemExit(f"CERTIFICATE_INVALID: {exc}")
    print(f"CERTIFICATE_VALID: NON_EVASIVE; states={state_count}")


if __name__ == "__main__":
    main()
