#
# This is now going to avoid touching/using the main vertices of the knot
# until the end for testing non-evasive.
#

import random
import time
import csv, ast, json, os
from datetime import datetime, timedelta, UTC
from sage.topology.simplicial_complex import SimplicialComplex
from pathlib import Path
from collections import Counter

knot_name = os.environ.get("KNOT_NAME")
# Seed
seed_env = os.environ.get("RANDOM_SEED")
if seed_env is not None:
    seed = int(seed_env)
else:
    seed = random.SystemRandom().randrange(1_000_000_000)

# Load Facets
facets_file = os.environ.get("FACETS_FILE")
def load_facets_from_file(path):
    with open(path, "r") as f:
        text = f.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return ast.literal_eval(text)

if facets_file:
    facets = load_facets_from_file(facets_file)

# build the initial Complex
K = SimplicialComplex(facets)

# List of vertices that should be touched last
LEAVE_UNTIL_LAST = frozenset([2,3,17])

# unknown_vertices 
unknown_vertices = LEAVE_UNTIL_LAST - set(K.vertices())
if unknown_vertices:
    raise ValueError("Protected vertices not found in K: " f"{sorted(unknown_vertices)}")

print(f"Protected vertices: {sorted(LEAVE_UNTIL_LAST)}", flush=True)
# add csv capabilities
CSV_OUTPUT = os.environ.get("CSV_OUTPUT", f"outputs/{seed_env}_{knot_name}.csv")

def export_proof_tree_to_csv(node, csv_path=CSV_OUTPUT):
    rows = []

    def walk(n, branch, depth):
        if n is None:
            return
        rows.append({
            "depth": depth,
            "branch": branch,
            "vertex": "" if n.vertex is None else n.vertex,
            "context": " ".join(map(str, n.context)),
        })
        walk(n.link, "link", depth + 1)
        walk(n.deletion, "deletion", depth + 1)

    walk(node, "root", 0)
    os.makedirs(os.path.dirname(csv_path), exist_ok = True)
    with open(csv_path, "w", newline = "") as f:
        writer = csv.DictWriter(f, fieldnames=["depth", "branch", "vertex", "context"])
        writer.writeheader()
        writer.writerows(rows)

# === Tree node for proof tracking ===
class ProofNode:
    def __init__(self, vertex, context):
        self.vertex = vertex
        self.context = tuple(context)
        self.link = None
        self.deletion = None

    def to_dict(self):
        return {
            "vertex": self.vertex,
            "context": self.context,
            "link": self.link.to_dict() if self.link else None,
            "deletion": self.deletion.to_dict() if self.deletion else None
        }

# Headbeat logger
HEARTBEAT_MODE = os.environ.get("HEARTBEAT_MODE", "stdout").lower()
HEARTBEAT_INTERVAL_SECONDS = int(os.environ.get("HEARTBEAT_INTERVAL_SECONDS", "86400"))

# Only used when HEARTBEAT_MODE=file
HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE", f"/outputs/heartbeat_{knot_name}.log")

last_heartbeat = 0

class SearchStats:
    def __init__(self):
        self.reset(0, None)

    def reset(self, initial_vertices, strategy):
        self.initial_vertices = int(initial_vertices)
        self.strategy = strategy
        self.vertex_attempts = 0
        self.recursive_calls = 0
        self.subcomplexes_examined = 0
        self.cache_hits = 0
        self.terminal_states_classified = 0
        self.deepest_path = 0

search_stats = SearchStats()

def log_heartbeat(status="running", result=None, elapsed_seconds=None):
    global last_heartbeat

    now = time.time()

    # Log heartbeat on interval, or always when status changes from running
    if now - last_heartbeat < HEARTBEAT_INTERVAL_SECONDS and status == "running":
        return

    last_heartbeat = now

    payload = {
        "type": "heartbeat",
        "schema_version": int(1),
        "status": status,
        "result": result,
        "timestamp": datetime.now(UTC).isoformat(),
        "container_id": knot_name,
        "strategy": search_stats.strategy,
        "seed": int(seed),
        "elapsed_seconds": elapsed_seconds,
        # Keep the old field as an alias for existing log consumers.
        "vertices_visited": int(search_stats.vertex_attempts),
        "vertex_attempts": int(search_stats.vertex_attempts),
        "recursive_calls": int(search_stats.recursive_calls),
        "subcomplexes_examined": int(search_stats.subcomplexes_examined),
        "cache_hits": int(search_stats.cache_hits),
        # "paths_completed" is retained as the user-facing short name. More
        # precisely, it counts unique terminal cache-miss states classified.
        "paths_completed": int(search_stats.terminal_states_classified),
        "terminal_states_classified": int(
            search_stats.terminal_states_classified
        ),
        "deepest_path": int(search_stats.deepest_path),
        "initial_vertices": int(search_stats.initial_vertices),
    }

    if HEARTBEAT_MODE == "file":
        heartbeat_dir = os.path.dirname(HEARTBEAT_FILE)

        if heartbeat_dir:
            os.makedirs(heartbeat_dir, exist_ok=True)

        with open(HEARTBEAT_FILE, "a") as f:
            json.dump(payload, f)
            f.write("\n")
    else:
        print(json.dumps(payload), flush=True)

# Safe Deletion function build into SageMath
def delete_vertex(K, v):
    new_K = SimplicialComplex(K.facets())
    new_K.remove_faces([[v]])
    return SimplicialComplex(new_K.facets())

def is_simplex(K):
    vertices = set(K.vertices())
    facets = list(K.facets())

    # Sage represents the empty complex with one empty facet, so the
    # nonempty-vertex check is required here.
    return (
        bool(vertices)
        and len(facets) == 1
        and set(facets[0]) == vertices
    )

def is_tree_complex(K):
    return K.dimension() == 1 and K.graph().is_tree()

def get_vertices_by_strategy(K, strategy="greedy", rng=None):
    if strategy == "greedy":
        vertices = sorted(
            K.vertices(),
            key=lambda x: (len(K.link([x]).facets()), x)
        )
    elif strategy == "random":
        vertices = list(K.vertices())
        (rng or random).shuffle(vertices)
    elif strategy == "max_degree":
        vertex_count = Counter(v for f in K.facets() for v in f)
        vertices = sorted(
            K.vertices(),
            key=lambda x: -vertex_count[x]
        )
    elif strategy == "lexical":
        vertices = sorted(K.vertices())
    elif strategy == "reverse_lexical":
        vertices = sorted(K.vertices(), reverse=True)
    elif strategy == "exhaustive":
        vertices = list(K.vertices())
    else:
        raise ValueError(f"Unknown strategy: {strategy}")

    unprotected_vertices = [
        v for v in vertices if v not in LEAVE_UNTIL_LAST
    ]

    # Do not select protected vertices while ordinary vertices remain.
    if unprotected_vertices:
        return unprotected_vertices
    
    # Once only protected vertices remain, allow them
    return vertices

def has_trivial_reduced_homology(K):
    homology = K.homology(reduced=True)
    return all(len(group.invariants()) == 0 for group in homology.values())

def complex_cache_key(K):
    # The labels matter because LEAVE_UNTIL_LAST is label-sensitive. Using
    # frozensets makes the key independent of Sage's facet iteration order.
    return frozenset(frozenset(facet) for facet in K.facets())

def classify_nonevasive_state(K):
    """Return True/False for a terminal state, or None if search is needed."""
    # Sage's empty complex has dimension -1 and one empty facet. It is not a
    # base case for non-evasiveness here, and several Sage predicates treat it
    # specially, so reject it explicitly.
    if not K.vertices():
        return False

    # These theorem-based terminal cases certify ordinary non-evasiveness.
    # LEAVE_UNTIL_LAST remains a priority for states that require search.
    if is_simplex(K) or K.cone_vertices():
        return True

    # Non-evasiveness for a one-dimensional complex is exactly the tree test.
    if K.dimension() == 1:
        return is_tree_complex(K)

    # Non-evasive complexes are contractible. Apply increasingly expensive
    # necessary conditions before starting any recursive branching.
    if not K.is_connected():
        return False

    if K.euler_characteristic() != 1:
        return False

    if not has_trivial_reduced_homology(K):
        return False

    return None

_CACHE_MISS = object()
_NO_WINNING_VERTEX = object()

def find_nonevasive_witness(
    K, witness_cache, strategy="random", rng=None, depth=0
):
    """Cache ``(verdict, winning_vertex)`` without building proof nodes.

    ``_NO_WINNING_VERTEX`` marks a terminal theorem/base case. Recursive
    successes store the vertex whose deletion and link both succeeded. The
    cache belongs to one run with a fixed strategy and protected-vertex policy.
    """
    search_stats.recursive_calls += 1
    search_stats.deepest_path = max(search_stats.deepest_path, depth)

    key = complex_cache_key(K)
    cached = witness_cache.get(key, _CACHE_MISS)
    if cached is not _CACHE_MISS:
        search_stats.cache_hits += 1
        return cached[0]

    search_stats.subcomplexes_examined += 1
    terminal_result = classify_nonevasive_state(K)
    if terminal_result is not None:
        # This is a leaf of the uncached search tree: a theorem/base success
        # or a topological rejection, rather than a memoized return.
        search_stats.terminal_states_classified += 1
        witness_cache[key] = (terminal_result, _NO_WINNING_VERTEX)
        return terminal_result

    vertices = get_vertices_by_strategy(K, strategy, rng=rng)
    for v in vertices:
        search_stats.vertex_attempts += 1
        log_heartbeat("running")

        del_k = delete_vertex(K, v)
        if not find_nonevasive_witness(
            del_k,
            witness_cache,
            strategy=strategy,
            rng=rng,
            depth=depth + 1,
        ):
            continue

        lk = K.link([v])
        if not find_nonevasive_witness(
            lk,
            witness_cache,
            strategy=strategy,
            rng=rng,
            depth=depth + 1,
        ):
            continue

        witness_cache[key] = (True, v)
        return True

    witness_cache[key] = (False, _NO_WINNING_VERTEX)
    return False

def build_proof_tree(K, witness_cache, context=()):
    """Reconstruct a ProofNode tree without rerunning the witness search."""
    key = complex_cache_key(K)
    cached = witness_cache.get(key, _CACHE_MISS)
    if cached is _CACHE_MISS:
        raise KeyError("No cached witness is available for this complex")

    is_non_evasive, winning_vertex = cached
    if not is_non_evasive:
        raise ValueError("Cannot build a proof tree for an evasive complex")

    if winning_vertex is _NO_WINNING_VERTEX:
        return ProofNode(None, context)

    node = ProofNode(winning_vertex, context)
    del_k = delete_vertex(K, winning_vertex)
    lk = K.link([winning_vertex])
    # Preserve the existing proof-output convention: only the root receives
    # the caller's ordering; recursive branch contexts start empty.
    node.deletion = build_proof_tree(del_k, witness_cache, context=())
    node.link = build_proof_tree(lk, witness_cache, context=())
    return node

def is_nonevasive(
    K,
    ordering=None,
    depth=0,
    strategy="random",
    context_path=(),
    mode=None,
    rng=None,
):
    if ordering is None:
        ordering = []
    search_stats.reset(len(K.vertices()), strategy)
    witness_cache = {}
    log_heartbeat("running")

    if not find_nonevasive_witness(
        K, witness_cache, strategy=strategy, rng=rng
    ):
        return [(None, None)]

    node = build_proof_tree(K, witness_cache, context=tuple(ordering))
    winning_vertex = witness_cache[complex_cache_key(K)][1]
    path = ordering.copy()
    if winning_vertex is not _NO_WINNING_VERTEX:
        path.append(winning_vertex)
    return [(path, node)]

# Run the test
start_time = time.time()
if seed_env is not None:
    seed = int(seed_env)
else:
    seed = random.SystemRandom().randrange(1_000_000_000)

print(f"Using Seed: {seed}", flush=True)
rng = random.Random(seed)
result_paths = is_nonevasive(K, strategy="greedy", rng=rng)
print("\n" + "="*50, flush=True)
final_result = "evasive"
if result_paths:
    path, node = result_paths[0]
    if path is not None:
        final_result = "non_evasive"
        print(f"✅ The complex is non-evasive. Found 1 valid deletion path.", flush=True)
        print("Deletion path:", path, flush=True)
        print("=== Deletion Decision Tree ===", flush=True)
        def print_tree(node, prefix=""):
            if node is None:
                return
            print(f"{prefix}Vertex {node.vertex} (Context: {node.context})", flush=True)
            if node.link:
                print(f"{prefix}  ↪ Link:", flush=True)
                print_tree(node.link, prefix + "    ")
                export_proof_tree_to_csv(node)
            if node.deletion:
                print(f"{prefix}  ↪ Deletion:", flush=True)
                print_tree(node.deletion, prefix + "    ")
                export_proof_tree_to_csv(node)
        if result_paths and result_paths[0][1]:
            print_tree(result_paths[0][1])
    else:
        print("❌ The complex is evasive. No deletion order found.", flush=True)

print("=== Search Statistics ===", flush=True)
print(f"Vertex attempts: {search_stats.vertex_attempts:,}", flush=True)
print(f"Recursive calls: {search_stats.recursive_calls:,}", flush=True)
print(
    f"Unique subcomplexes examined: {search_stats.subcomplexes_examined:,}",
    flush=True,
)
print(f"Cache hits: {search_stats.cache_hits:,}", flush=True)
print(
    f"Terminal states classified: "
    f"{search_stats.terminal_states_classified:,}",
    flush=True,
)
print(
    f"Deepest path: {search_stats.deepest_path:,} / "
    f"{search_stats.initial_vertices:,} vertices",
    flush=True,
)

end_time = time.time()
elapsed = end_time - start_time
pretty_time = str(timedelta(seconds=int(elapsed)))
print(
    f"FINAL_RESULT: {final_result}; "
    f"vertex_attempts={search_stats.vertex_attempts}; "
    f"subcomplexes_examined={search_stats.subcomplexes_examined}; "
    f"cache_hits={search_stats.cache_hits}",
    flush=True,
)
print(pretty_time, flush=True)
log_heartbeat(
    "completed", result=final_result, elapsed_seconds=float(elapsed)
)
