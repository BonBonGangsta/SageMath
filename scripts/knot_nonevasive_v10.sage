#
# This is now going to avoid touching/using the main vertices of the knot
# until the end for testing non-evasive.
#

import random
import time
import resource
import csv, ast, json, os
from datetime import datetime, timedelta, UTC
from sage.topology.simplicial_complex import SimplicialComplex
from pathlib import Path
from collections import Counter, OrderedDict, deque

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

# Heartbeat logger
HEARTBEAT_MODE = os.environ.get("HEARTBEAT_MODE", "stdout").lower()
HEARTBEAT_INTERVAL_SECONDS = int(os.environ.get("HEARTBEAT_INTERVAL_SECONDS", "300"))
WITNESS_CACHE_MAX_FAILURES = int(
    os.environ.get("WITNESS_CACHE_MAX_FAILURES", "500000")
)

if HEARTBEAT_INTERVAL_SECONDS <= 0:
    raise ValueError("HEARTBEAT_INTERVAL_SECONDS must be positive")

if WITNESS_CACHE_MAX_FAILURES < 0:
    raise ValueError("WITNESS_CACHE_MAX_FAILURES cannot be negative")

# Only used when HEARTBEAT_MODE=file
HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE", f"/outputs/heartbeat_{knot_name}.log")

last_heartbeat = 0

_CACHE_MISS = object()
_NO_WINNING_VERTEX = object()


def get_memory_usage_mib():
    """Return current and peak resident memory on the Linux Sage runner."""
    current_rss_mib = None

    try:
        with open("/proc/self/status", "r") as status_file:
            for line in status_file:
                if line.startswith("VmRSS:"):
                    current_rss_mib = (
                        float(int(line.split()[1])) / int(1024)
                    )
                    break
    except (OSError, ValueError, IndexError):
        pass

    # Linux reports ru_maxrss in KiB.
    peak_rss_mib = (
        float(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        / int(1024)
    )
    if current_rss_mib is not None:
        peak_rss_mib = max(peak_rss_mib, current_rss_mib)
    return current_rss_mib, peak_rss_mib

class SearchStats:
    def __init__(self):
        self.reset(0, None)

    def reset(self, initial_vertices, strategy):
        self.initial_vertices = int(initial_vertices)
        self.strategy = strategy
        self.phase = "search"
        self.started_at = time.time()
        self.vertex_attempts = 0
        self.recursive_calls = 0
        self.subcomplexes_examined = 0
        self.cache_hits = 0
        self.cache_entries = 0
        self.cache_peak_entries = 0
        self.cache_success_entries = 0
        self.cache_failure_entries = 0
        self.cache_evictions = 0
        self.terminal_states_classified = 0
        self.deepest_path = 0

    def update_cache_sizes(self, success_entries, failure_entries):
        self.cache_success_entries = int(success_entries)
        self.cache_failure_entries = int(failure_entries)
        self.cache_entries = int(success_entries + failure_entries)
        self.cache_peak_entries = max(
            self.cache_peak_entries, self.cache_entries
        )

search_stats = SearchStats()


class WitnessCache:
    """Compact witnesses plus a bounded LRU of failed search states.

    Successful states must remain available to reconstruct the proof after the
    Boolean search succeeds. Failed states can be evicted safely: an evicted
    state may be recomputed, but the mathematical result is unchanged.
    """

    def __init__(self, max_failures=WITNESS_CACHE_MAX_FAILURES):
        self.max_failures = int(max_failures)
        if self.max_failures < 0:
            raise ValueError("max_failures cannot be negative")

        self._successes = {}
        self._failures = OrderedDict()
        self._update_stats()

    def _update_stats(self):
        search_stats.update_cache_sizes(
            len(self._successes), len(self._failures)
        )

    def lookup(self, state_key):
        winning_vertex = self._successes.get(state_key, _CACHE_MISS)
        if winning_vertex is not _CACHE_MISS:
            return (True, winning_vertex)

        if state_key in self._failures:
            self._failures.move_to_end(state_key)
            return (False, _NO_WINNING_VERTEX)

        return _CACHE_MISS

    def store(self, state_key, verdict, winning_vertex):
        if verdict:
            self._failures.pop(state_key, None)
            self._successes[state_key] = winning_vertex
        elif self.max_failures:
            self._failures[state_key] = None
            self._failures.move_to_end(state_key)

            if len(self._failures) > self.max_failures:
                self._failures.popitem(last=False)
                search_stats.cache_evictions += 1

        self._update_stats()

    def get_winning_vertex(self, state_key):
        winning_vertex = self._successes.get(state_key, _CACHE_MISS)
        if winning_vertex is _CACHE_MISS:
            raise KeyError("No successful witness is cached for this state")
        return winning_vertex


def log_heartbeat(
    status="running", result=None, elapsed_seconds=None, force=False
):
    global last_heartbeat

    now = time.time()

    # Log heartbeat on interval, or always when status changes from running
    if (
        not force
        and now - last_heartbeat < HEARTBEAT_INTERVAL_SECONDS
        and status == "running"
    ):
        return

    last_heartbeat = now

    if elapsed_seconds is None:
        elapsed_seconds = now - search_stats.started_at

    current_rss_mib, peak_rss_mib = get_memory_usage_mib()

    payload = {
        "type": "heartbeat",
        "schema_version": int(2),
        "status": status,
        "result": result,
        "timestamp": datetime.now(UTC).isoformat(),
        "container_id": knot_name,
        "strategy": search_stats.strategy,
        "phase": search_stats.phase,
        "seed": int(seed),
        "elapsed_seconds": float(elapsed_seconds),
        # Keep the old field as an alias for existing log consumers.
        "vertices_visited": int(search_stats.vertex_attempts),
        "vertex_attempts": int(search_stats.vertex_attempts),
        "recursive_calls": int(search_stats.recursive_calls),
        # With a bounded failure cache, an evicted state can be examined
        # again. This is therefore an exact cache-miss count; it is also the
        # unique-state count whenever cache_evictions is zero.
        "subcomplexes_examined": int(search_stats.subcomplexes_examined),
        "cache_misses": int(search_stats.subcomplexes_examined),
        "cache_hits": int(search_stats.cache_hits),
        "cache_entries": int(search_stats.cache_entries),
        "cache_peak_entries": int(search_stats.cache_peak_entries),
        "cache_success_entries": int(search_stats.cache_success_entries),
        "cache_failure_entries": int(search_stats.cache_failure_entries),
        "cache_failure_limit": int(WITNESS_CACHE_MAX_FAILURES),
        "cache_evictions": int(search_stats.cache_evictions),
        "cache_key_format": "linked_deleted_bitmasks",
        # "paths_completed" is retained as the user-facing short name. More
        # precisely, it counts terminal cache-miss classifications. A state
        # can be counted again if it was evicted and later revisited.
        "paths_completed": int(search_stats.terminal_states_classified),
        "terminal_states_classified": int(
            search_stats.terminal_states_classified
        ),
        "deepest_path": int(search_stats.deepest_path),
        "initial_vertices": int(search_stats.initial_vertices),
        "current_rss_mib": (
            None
            if current_rss_mib is None
            else float(round(current_rss_mib, int(3)))
        ),
        "peak_rss_mib": float(round(peak_rss_mib, int(3))),
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

def build_root_distances(K):
    """Return fixed 1-skeleton distances from the protected vertex set."""
    root_vertices = set(K.vertices())
    sources = sorted(root_vertices & LEAVE_UNTIL_LAST)
    if not sources:
        raise ValueError("No protected vertices are present in the root complex")

    graph = K.graph()
    distances = {vertex: int(0) for vertex in sources}
    queue = deque(sources)

    while queue:
        vertex = queue.popleft()
        next_distance = distances[vertex] + int(1)
        for neighbor in graph.neighbor_iterator(vertex):
            if neighbor not in distances:
                distances[neighbor] = next_distance
                queue.append(neighbor)

    # A disconnected root is rejected by classify_nonevasive_state before
    # candidate ordering. Still return a total map so this helper is robust.
    unreachable_distance = len(root_vertices) + int(1)
    for vertex in root_vertices - set(distances):
        distances[vertex] = unreachable_distance

    return distances

def get_vertices_by_strategy(
    K, strategy="greedy", rng=None, root_distances=None
):
    if strategy == "greedy":
        vertices = sorted(
            K.vertices(),
            key=lambda x: (len(K.link([x]).facets()), x)
        )
    elif strategy == "outer_layer":
        if root_distances is None:
            raise ValueError("outer_layer requires root distances")

        vertices = sorted(
            K.vertices(),
            key=lambda v: (
                -root_distances[v],          # farthest first
                len(K.link([v]).facets()),   # smallest link first
                v,                           # deterministic tie-break
            ),
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

def build_vertex_bits(K):
    """Assign one Python-integer bit to every vertex of the fixed root."""
    return {
        vertex: int(1) << index
        for index, vertex in enumerate(K.vertices())
    }

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

def find_nonevasive_witness(
    K,
    witness_cache,
    vertex_bits,
    strategy="random",
    rng=None,
    root_distances=None,
    state_key=(int(0), int(0)),
    depth=0,
):
    """Cache verdicts under compact link/deletion histories.

    ``_NO_WINNING_VERTEX`` marks a terminal theorem/base case. Recursive
    successes store the vertex whose deletion and link both succeeded.

    A state key is ``(linked_mask, deleted_mask)`` relative to this run's fixed
    root complex. Links and deletions at distinct vertices commute, so the two
    sets determine the resulting state exactly. Different histories can
    occasionally produce the same complex under different keys; that only
    misses a cache-sharing opportunity and cannot produce a false cache hit.
    """
    search_stats.recursive_calls += 1
    search_stats.deepest_path = max(search_stats.deepest_path, depth)

    cached = witness_cache.lookup(state_key)
    if cached is not _CACHE_MISS:
        search_stats.cache_hits += 1
        return cached[0]

    search_stats.subcomplexes_examined += 1
    terminal_result = classify_nonevasive_state(K)
    if terminal_result is not None:
        # This is a leaf of the uncached search tree: a theorem/base success
        # or a topological rejection, rather than a memoized return.
        search_stats.terminal_states_classified += 1
        witness_cache.store(
            state_key, terminal_result, _NO_WINNING_VERTEX
        )
        return terminal_result

    vertices = get_vertices_by_strategy(
        K,
        strategy,
        rng=rng,
        root_distances=root_distances,
    )
    for v in vertices:
        search_stats.vertex_attempts += 1
        log_heartbeat("running")

        linked_mask, deleted_mask = state_key
        vertex_bit = vertex_bits[v]
        if linked_mask & deleted_mask:
            raise RuntimeError("Linked and deleted vertex masks overlap")
        if (linked_mask | deleted_mask) & vertex_bit:
            raise RuntimeError("A decided vertex was selected again")

        del_k = delete_vertex(K, v)
        if not find_nonevasive_witness(
            del_k,
            witness_cache,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=(linked_mask, deleted_mask | vertex_bit),
            depth=depth + 1,
        ):
            continue

        lk = K.link([v])
        if not find_nonevasive_witness(
            lk,
            witness_cache,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=(linked_mask | vertex_bit, deleted_mask),
            depth=depth + 1,
        ):
            continue

        witness_cache.store(state_key, True, v)
        return True

    witness_cache.store(state_key, False, _NO_WINNING_VERTEX)
    return False

def build_proof_tree(
    K,
    witness_cache,
    vertex_bits,
    state_key=(int(0), int(0)),
    context=(),
):
    """Reconstruct a ProofNode tree without rerunning the witness search."""
    winning_vertex = witness_cache.get_winning_vertex(state_key)

    if winning_vertex is _NO_WINNING_VERTEX:
        return ProofNode(None, context)

    node = ProofNode(winning_vertex, context)
    del_k = delete_vertex(K, winning_vertex)
    lk = K.link([winning_vertex])
    linked_mask, deleted_mask = state_key
    vertex_bit = vertex_bits[winning_vertex]
    # Preserve the existing proof-output convention: only the root receives
    # the caller's ordering; recursive branch contexts start empty.
    node.deletion = build_proof_tree(
        del_k,
        witness_cache,
        vertex_bits,
        state_key=(linked_mask, deleted_mask | vertex_bit),
        context=(),
    )
    node.link = build_proof_tree(
        lk,
        witness_cache,
        vertex_bits,
        state_key=(linked_mask | vertex_bit, deleted_mask),
        context=(),
    )
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
    vertex_bits = build_vertex_bits(K)
    witness_cache = WitnessCache()
    root_state_key = (int(0), int(0))
    log_heartbeat("running", force=True)
    root_distances = (
        build_root_distances(K) if strategy == "outer_layer" else None
    )

    if not find_nonevasive_witness(
        K,
        witness_cache,
        vertex_bits,
        strategy=strategy,
        rng=rng,
        root_distances=root_distances,
        state_key=root_state_key,
    ):
        search_stats.phase = "search_complete"
        return [(None, None)]

    search_stats.phase = "proof_reconstruction"
    log_heartbeat("running", force=True)
    node = build_proof_tree(
        K,
        witness_cache,
        vertex_bits,
        state_key=root_state_key,
        context=tuple(ordering),
    )
    search_stats.phase = "proof_complete"
    winning_vertex = witness_cache.get_winning_vertex(root_state_key)
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
result_paths = is_nonevasive(K, strategy="outer_layer", rng=rng)
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
print(f"Subcomplex cache misses: {search_stats.subcomplexes_examined:,}", flush=True)
print(f"Cache hits: {search_stats.cache_hits:,}", flush=True)
print(
    f"Cache entries: {search_stats.cache_entries:,} current / "
    f"{search_stats.cache_peak_entries:,} peak "
    f"({search_stats.cache_success_entries:,} successful, "
    f"{search_stats.cache_failure_entries:,} failed)",
    flush=True,
)
print(f"Failure-cache evictions: {search_stats.cache_evictions:,}", flush=True)
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
current_rss_mib, peak_rss_mib = get_memory_usage_mib()
if current_rss_mib is not None:
    print(
        f"Resident memory: {current_rss_mib:,.1f} MiB current / "
        f"{peak_rss_mib:,.1f} MiB peak",
        flush=True,
    )

end_time = time.time()
elapsed = end_time - start_time
pretty_time = str(timedelta(seconds=int(elapsed)))
print(
    f"FINAL_RESULT: {final_result}; "
    f"vertex_attempts={search_stats.vertex_attempts}; "
    f"subcomplexes_examined={search_stats.subcomplexes_examined}; "
    f"cache_hits={search_stats.cache_hits}; "
    f"cache_evictions={search_stats.cache_evictions}",
    flush=True,
)
print(pretty_time, flush=True)
search_stats.phase = "completed"
log_heartbeat(
    "completed", result=final_result, elapsed_seconds=float(elapsed)
)
