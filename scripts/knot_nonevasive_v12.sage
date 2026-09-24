"""Version 12 of the exact non-evasiveness search.

Protected vertices are a complete, soft ordering preference by default. The
historical hard restriction remains available explicitly, but a failed
restricted search is reported as inconclusive rather than evasive.
"""

import random
import time
import resource
import ast, hashlib, json, math, os, subprocess, sys
from datetime import datetime, timedelta, UTC
from sage.all import GF, ZZ
from sage.topology.simplicial_complex import SimplicialComplex
from pathlib import Path
from collections import Counter, OrderedDict, deque

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

from simplicial_bitset import RootBitsetComplex

# Seed
seed_env = os.environ.get("RANDOM_SEED")
if seed_env is not None:
    try:
        seed = int(seed_env)
    except ValueError as exc:
        raise ValueError("RANDOM_SEED must be an integer") from exc
else:
    seed = random.SystemRandom().randrange(1_000_000_000)

# Load Facets
facets_file = os.environ.get("FACETS_FILE")

def load_facets_from_file(path):
    with open(path, "r") as f:
        text = f.read()
    try:
        loaded_facets = json.loads(text)
    except json.JSONDecodeError:
        loaded_facets = ast.literal_eval(text)

    if not isinstance(loaded_facets, (list, tuple)):
        raise ValueError("The facets file must contain a list of facets")
    if not loaded_facets:
        raise ValueError("The facets file must contain at least one facet")

    normalized_facets = []
    for index, facet in enumerate(loaded_facets, start=1):
        if not isinstance(facet, (list, tuple)):
            raise ValueError(f"Facet {index} must be a list or tuple")
        if not facet:
            raise ValueError(f"Facet {index} cannot be empty")
        if any(type(vertex) is not int for vertex in facet):
            raise ValueError(
                f"Facet {index} contains a non-integer vertex label"
            )
        if len(set(facet)) != len(facet):
            raise ValueError(f"Facet {index} repeats a vertex")
        normalized_facets.append(list(facet))
    return normalized_facets

if not facets_file:
    raise SystemExit("Set FACETS_FILE to the path of a facets file.")
if not os.path.isfile(facets_file):
    raise FileNotFoundError(f"FACETS_FILE was not found: {facets_file}")

facets = load_facets_from_file(facets_file)
knot_name = os.environ.get("KNOT_NAME") or Path(facets_file).stem

# build the initial Complex
K = SimplicialComplex(facets)

RESULT_NON_EVASIVE = "NON_EVASIVE"
RESULT_EVASIVE_CERTIFIED = "EVASIVE_CERTIFIED"
RESULT_INCONCLUSIVE_RESTRICTED = "INCONCLUSIVE_RESTRICTED"
RESULT_INCONCLUSIVE_RESOURCE_LIMIT = "INCONCLUSIVE_RESOURCE_LIMIT"


def load_protected_vertices(raw_value):
    """Parse an integer or integer collection from an environment setting."""
    if raw_value is None or not raw_value.strip():
        return frozenset()

    text = raw_value.strip()
    try:
        values = json.loads(text)
    except json.JSONDecodeError:
        try:
            values = ast.literal_eval(text)
        except (SyntaxError, ValueError) as exc:
            raise ValueError(
                "PROTECTED_VERTICES must be an integer or a list/tuple "
                "of integers"
            ) from exc

    if type(values) is int:
        values = [values]
    if not isinstance(values, (list, tuple, set, frozenset)):
        raise ValueError(
            "PROTECTED_VERTICES must be an integer or a list/tuple "
            "of integers"
        )
    if any(type(vertex) is not int for vertex in values):
        raise ValueError("PROTECTED_VERTICES may contain only integers")
    if len(set(values)) != len(values):
        raise ValueError("PROTECTED_VERTICES cannot repeat a vertex")
    return frozenset(values)


PROTECTED_VERTICES = load_protected_vertices(
    os.environ.get("PROTECTED_VERTICES")
)
PROTECTED_VERTEX_POLICY = os.environ.get(
    "PROTECTED_VERTEX_POLICY", "prefer"
).strip().lower()
VALID_PROTECTED_VERTEX_POLICIES = frozenset(
    {"prefer", "restrict", "ignore"}
)
if PROTECTED_VERTEX_POLICY not in VALID_PROTECTED_VERTEX_POLICIES:
    raise ValueError(
        "PROTECTED_VERTEX_POLICY must be one of: prefer, restrict, ignore"
    )

# unknown_vertices 
unknown_vertices = PROTECTED_VERTICES - set(K.vertices())
if unknown_vertices:
    raise ValueError("Protected vertices not found in K: " f"{sorted(unknown_vertices)}")

print(f"Protected vertices: {sorted(PROTECTED_VERTICES)}", flush=True)
print(f"Protected vertex policy: {PROTECTED_VERTEX_POLICY}", flush=True)
CERTIFICATE_OUTPUT = os.environ.get(
    "CERTIFICATE_OUTPUT",
    f"outputs/{seed}_{knot_name}_certificate.json",
)

# Heartbeat logger
HEARTBEAT_MODE = os.environ.get("HEARTBEAT_MODE", "stdout").lower()
HEARTBEAT_INTERVAL_SECONDS = int(os.environ.get("HEARTBEAT_INTERVAL_SECONDS", "43200"))
WITNESS_CACHE_MAX_FAILURES = int(
    os.environ.get("WITNESS_CACHE_MAX_FAILURES", "500000")
)
STATE_ENGINE = os.environ.get("STATE_ENGINE", "bitset").strip().lower()
VALID_STATE_ENGINES = frozenset({"bitset", "sage_reference"})
if STATE_ENGINE not in VALID_STATE_ENGINES:
    raise ValueError("STATE_ENGINE must be one of: bitset, sage_reference")
SEARCH_STATE_LIMIT = int(os.environ.get("SEARCH_STATE_LIMIT", "0"))
SEARCH_TIME_LIMIT_SECONDS = float(
    os.environ.get("SEARCH_TIME_LIMIT_SECONDS", "0")
)
if SEARCH_STATE_LIMIT < 0:
    raise ValueError("SEARCH_STATE_LIMIT cannot be negative")
if (
    not math.isfinite(SEARCH_TIME_LIMIT_SECONDS)
    or SEARCH_TIME_LIMIT_SECONDS < 0
):
    raise ValueError(
        "SEARCH_TIME_LIMIT_SECONDS must be a finite nonnegative number"
    )


def get_boolean_environment_setting(name, default):
    value = os.environ.get(name)
    if value is None:
        return bool(default)

    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(
        f"{name} must be one of: 1/0, true/false, yes/no, on/off"
    )


# Adaptive homology policy. Integral homology is always used at the root
# after the cheaper terminal tests. A descendant is considered small when it
# meets either enabled ZZ threshold. Larger direct-link states and periodic
# depth checkpoints receive the cheaper GF(2) rejection screen instead.
HOMOLOGY_ZZ_MAX_VERTICES = int(
    os.environ.get("HOMOLOGY_ZZ_MAX_VERTICES", "80")
)
HOMOLOGY_ZZ_MAX_FACES = int(
    os.environ.get("HOMOLOGY_ZZ_MAX_FACES", "1500")
)
HOMOLOGY_START_DEPTH = int(
    os.environ.get("HOMOLOGY_START_DEPTH", "200")
)
HOMOLOGY_GF2_DEPTH_INTERVAL = int(
    os.environ.get("HOMOLOGY_GF2_DEPTH_INTERVAL", "20")
)
HOMOLOGY_GF2_ON_LINKS = get_boolean_environment_setting(
    "HOMOLOGY_GF2_ON_LINKS", True
)
GF2 = GF(2)

if HEARTBEAT_INTERVAL_SECONDS <= 0:
    raise ValueError("HEARTBEAT_INTERVAL_SECONDS must be positive")

if WITNESS_CACHE_MAX_FAILURES < 0:
    raise ValueError("WITNESS_CACHE_MAX_FAILURES cannot be negative")

if HOMOLOGY_ZZ_MAX_VERTICES < 0:
    raise ValueError("HOMOLOGY_ZZ_MAX_VERTICES cannot be negative")

if HOMOLOGY_ZZ_MAX_FACES < 0:
    raise ValueError("HOMOLOGY_ZZ_MAX_FACES cannot be negative")

if HOMOLOGY_START_DEPTH < 0:
    raise ValueError("HOMOLOGY_START_DEPTH cannot be negative")

if HOMOLOGY_GF2_DEPTH_INTERVAL < 0:
    raise ValueError("HOMOLOGY_GF2_DEPTH_INTERVAL cannot be negative")

# Only used when HEARTBEAT_MODE=file
HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE", f"/outputs/heartbeat_{knot_name}.log")

last_heartbeat = 0

_CACHE_MISS = object()
_NO_WINNING_VERTEX = object()


class SearchResourceLimitReached(RuntimeError):
    """Internal control flow for a sound, explicitly inconclusive stop."""

    def __init__(self, kind, configured_limit, observed_value):
        self.kind = kind
        self.configured_limit = configured_limit
        self.observed_value = observed_value
        super().__init__(
            f"{kind} reached: configured={configured_limit}, "
            f"observed={observed_value}"
        )


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
        self.started_monotonic = time.monotonic()
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
        self.link_recursive_calls = 0
        self.deletion_recursive_calls = 0
        self.link_first_rejections = 0
        self.sage_state_materializations = 0
        self.bitset_state_reconstructions = 0
        self.resource_limit_kind = None
        self.resource_limit_configured = None
        self.resource_limit_observed = None
        self.homology_zz_calls = 0
        self.homology_gf2_calls = 0
        self.homology_zz_seconds = 0.0
        self.homology_gf2_seconds = 0.0
        self.homology_zz_rejections = 0
        self.homology_gf2_rejections = 0
        self.homology_skipped = 0
        self.restricted_vertices_skipped = 0

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

class CertificateStore:
    """Retain proof records independently of cache eviction policy."""

    def __init__(self):
        self._records = {}

    def _store(self, state_key, record):
        existing = self._records.get(state_key)
        if existing is not None and existing != record:
            raise RuntimeError(
                f"Conflicting certificate records for state {state_key}"
            )
        self._records[state_key] = record

    def store_terminal(self, state_key, verdict, reason):
        self._store(
            state_key,
            {
                "verdict": (
                    RESULT_NON_EVASIVE if verdict
                    else RESULT_EVASIVE_CERTIFIED
                ),
                "terminal_reason": reason,
            },
        )

    def store_success(
        self, state_key, winning_vertex, deletion_child, link_child
    ):
        self._store(
            state_key,
            {
                "verdict": RESULT_NON_EVASIVE,
                "winning_vertex": int(winning_vertex),
                "deletion_child": deletion_child,
                "link_child": link_child,
            },
        )

    def store_failure(self, state_key, failed_children):
        record = {
            "verdict": RESULT_EVASIVE_CERTIFIED,
            "failed_children": [
                {
                    "vertex": int(failure["vertex"]),
                    "branch": failure["branch"],
                    "child": failure["child"],
                }
                for failure in failed_children
            ],
        }
        existing = self._records.get(state_key)
        if existing is None:
            self._records[state_key] = record
        elif existing.get("verdict") != RESULT_EVASIVE_CERTIFIED:
            raise RuntimeError(
                f"Conflicting certificate verdict for state {state_key}"
            )

    def get(self, state_key):
        try:
            return self._records[state_key]
        except KeyError as exc:
            raise KeyError(
                f"Missing certificate record for state {state_key}"
            ) from exc


def certificate_state_id(state_key):
    linked_mask, deleted_mask = state_key
    return f"L{linked_mask:x}-D{deleted_mask:x}"


def canonical_facets(K):
    """Return stable integer facets for hashing and verification."""
    return sorted(
        (sorted(int(vertex) for vertex in facet) for facet in K.facets()),
        key=lambda facet: (len(facet), facet),
    )


def canonical_complex_sha256(K):
    encoded = json.dumps(
        canonical_facets(K), separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def current_git_revision():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=Path.cwd(),
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def current_sage_version():
    try:
        import sage.version
        return str(sage.version.version)
    except (AttributeError, ImportError):
        return None


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
        "schema_version": int(3),
        "status": status,
        "result": result,
        "timestamp": datetime.now(UTC).isoformat(),
        "container_id": knot_name,
        "strategy": search_stats.strategy,
        "state_engine": STATE_ENGINE,
        "search_state_limit": int(SEARCH_STATE_LIMIT),
        "search_time_limit_seconds": float(SEARCH_TIME_LIMIT_SECONDS),
        "resource_limit_kind": search_stats.resource_limit_kind,
        "resource_limit_configured": search_stats.resource_limit_configured,
        "resource_limit_observed": search_stats.resource_limit_observed,
        "protected_vertex_policy": PROTECTED_VERTEX_POLICY,
        "protected_vertices": sorted(PROTECTED_VERTICES),
        "restricted_vertices_skipped": int(
            search_stats.restricted_vertices_skipped
        ),
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
        "link_recursive_calls": int(search_stats.link_recursive_calls),
        "deletion_recursive_calls": int(
            search_stats.deletion_recursive_calls
        ),
        "link_first_rejections": int(
            search_stats.link_first_rejections
        ),
        "sage_state_materializations": int(
            search_stats.sage_state_materializations
        ),
        "bitset_state_reconstructions": int(
            search_stats.bitset_state_reconstructions
        ),
        "homology_policy": "adaptive_zz_gf2",
        "homology_start_depth": int(HOMOLOGY_START_DEPTH),
        "homology_zz_max_vertices": int(HOMOLOGY_ZZ_MAX_VERTICES),
        "homology_zz_max_faces": int(HOMOLOGY_ZZ_MAX_FACES),
        "homology_gf2_depth_interval": int(
            HOMOLOGY_GF2_DEPTH_INTERVAL
        ),
        "homology_gf2_on_links": bool(HOMOLOGY_GF2_ON_LINKS),
        "homology_zz_calls": int(search_stats.homology_zz_calls),
        "homology_gf2_calls": int(search_stats.homology_gf2_calls),
        "homology_zz_seconds": float(
            round(search_stats.homology_zz_seconds, int(6))
        ),
        "homology_gf2_seconds": float(
            round(search_stats.homology_gf2_seconds, int(6))
        ),
        "homology_zz_rejections": int(
            search_stats.homology_zz_rejections
        ),
        "homology_gf2_rejections": int(
            search_stats.homology_gf2_rejections
        ),
        "homology_skipped": int(search_stats.homology_skipped),
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
    sources = sorted(root_vertices & PROTECTED_VERTICES)
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

    if not PROTECTED_VERTICES or PROTECTED_VERTEX_POLICY == "ignore":
        return vertices

    unprotected_vertices = [
        vertex for vertex in vertices if vertex not in PROTECTED_VERTICES
    ]
    protected_vertices = [
        vertex for vertex in vertices if vertex in PROTECTED_VERTICES
    ]

    # The default policy is complete: protected vertices are tried last but
    # remain candidates. The explicit restrict policy reproduces the older
    # experimental behavior and must not report an ordinary evasiveness proof
    # if it actually omits candidates.
    if PROTECTED_VERTEX_POLICY == "prefer":
        return unprotected_vertices + protected_vertices

    if unprotected_vertices:
        search_stats.restricted_vertices_skipped += len(protected_vertices)
        return unprotected_vertices

    return protected_vertices

def homology_group_is_trivial(group, ring_name):
    """Handle Sage's different ZZ-group and field-vector-space results."""
    if ring_name == "ZZ":
        return len(group.invariants()) == 0
    return int(group.dimension()) == 0


def has_trivial_reduced_homology(
    K, base_ring, ring_name, depth=None
):
    """Run and time one sound homology rejection test."""
    if ring_name == "ZZ":
        search_stats.homology_zz_calls += 1
    else:
        search_stats.homology_gf2_calls += 1

    # Emit explicit root-homology boundaries. If the operating system kills
    # the process during this relatively expensive step, the final log line
    # identifies the operation that was in progress.
    is_root_test = depth == 0
    previous_phase = search_stats.phase
    if is_root_test:
        search_stats.phase = f"root_homology_{ring_name.lower()}"
        log_heartbeat("running", force=True)

    started_at = time.perf_counter()
    try:
        homology = K.homology(reduced=True, base_ring=base_ring)
    finally:
        elapsed = time.perf_counter() - started_at
        if ring_name == "ZZ":
            search_stats.homology_zz_seconds += elapsed
        else:
            search_stats.homology_gf2_seconds += elapsed
        if is_root_test:
            search_stats.phase = previous_phase
            log_heartbeat("running", force=True)

    is_trivial = all(
        homology_group_is_trivial(group, ring_name)
        for group in homology.values()
    )
    if not is_trivial:
        if ring_name == "ZZ":
            search_stats.homology_zz_rejections += 1
        else:
            search_stats.homology_gf2_rejections += 1
    return is_trivial


def homology_test_for_state(K, depth, is_link_state):
    """Choose ZZ, GF(2), or no homology test for this cache miss."""

    # Keep the one-time integral root check.
    if depth == 0:
        return (ZZ, "ZZ")

    # Do not run descendant homology before the configured depth.
    # This also gates direct-link homology.
    if depth < HOMOLOGY_START_DEPTH:
        return None

    vertex_count = len(K.vertices())

    # Use integral homology once the state is sufficiently small.
    if (
        HOMOLOGY_ZZ_MAX_VERTICES > 0
        and vertex_count <= HOMOLOGY_ZZ_MAX_VERTICES
    ):
        return (ZZ, "ZZ")

    if HOMOLOGY_ZZ_MAX_FACES > 0:
        # f_vector()[0] is the empty face.
        nonempty_face_count = sum(
            int(n) for n in K.f_vector()[1:]
        )
        if nonempty_face_count <= HOMOLOGY_ZZ_MAX_FACES:
            return (ZZ, "ZZ")

    # With start=200 and interval=20, checkpoints are
    # 200, 220, 240, ...
    is_checkpoint = (
        HOMOLOGY_GF2_DEPTH_INTERVAL > 0
        and (
            depth - HOMOLOGY_START_DEPTH
        ) % HOMOLOGY_GF2_DEPTH_INTERVAL == 0
    )

    if (HOMOLOGY_GF2_ON_LINKS and is_link_state) or is_checkpoint:
        return (GF2, "GF2")

    return None

def materialize_search_state(root_K, root_bitset, state_key):
    """Build one Sage state after a cache miss using the selected engine."""
    linked_mask, deleted_mask = state_key

    if STATE_ENGINE == "bitset":
        facet_masks = root_bitset.state_facets(
            linked_mask, deleted_mask
        )
        state = root_bitset.sage_complex(facet_masks)
        search_stats.bitset_state_reconstructions += 1
    else:
        # This deliberately independent reference path replays Sage links and
        # deletions from the root. It remains available for equivalence tests,
        # not as the recommended engine for long searches.
        if linked_mask & deleted_mask:
            raise RuntimeError("Linked and deleted vertex masks overlap")
        if (
            linked_mask | deleted_mask
        ) & ~root_bitset.all_vertices_mask:
            raise RuntimeError("A state mask contains an unknown vertex bit")
        state = SimplicialComplex(root_K.facets())
        for index, vertex in enumerate(root_bitset.vertex_order):
            vertex_bit = int(1) << index
            if linked_mask & vertex_bit:
                state = state.link([vertex])
        for index, vertex in enumerate(root_bitset.vertex_order):
            vertex_bit = int(1) << index
            if deleted_mask & vertex_bit and vertex in state.vertices():
                state = delete_vertex(state, vertex)

    search_stats.sage_state_materializations += 1
    return state


def stop_for_resource_limit(kind, configured_limit, observed_value):
    search_stats.resource_limit_kind = kind
    search_stats.resource_limit_configured = configured_limit
    search_stats.resource_limit_observed = observed_value
    search_stats.phase = "resource_limit"
    raise SearchResourceLimitReached(
        kind, configured_limit, observed_value
    )


def enforce_search_time_limit():
    """Cooperatively stop between search operations when time is exhausted."""
    if SEARCH_TIME_LIMIT_SECONDS <= 0:
        return
    elapsed = time.monotonic() - search_stats.started_monotonic
    if elapsed >= SEARCH_TIME_LIMIT_SECONDS:
        stop_for_resource_limit(
            "time_limit_seconds",
            float(SEARCH_TIME_LIMIT_SECONDS),
            float(elapsed),
        )


def enforce_search_state_limit_before_miss():
    """Allow at most the configured number of cache-miss states."""
    if (
        SEARCH_STATE_LIMIT > 0
        and search_stats.subcomplexes_examined >= SEARCH_STATE_LIMIT
    ):
        stop_for_resource_limit(
            "state_limit",
            int(SEARCH_STATE_LIMIT),
            int(search_stats.subcomplexes_examined),
        )

def classify_nonevasive_state(K, depth=0, is_link_state=False):
    """Return ``(verdict, reason)``; verdict is None when search is needed."""
    # Sage's empty complex has dimension -1 and one empty facet. It is not a
    # base case for non-evasiveness here, and several Sage predicates treat it
    # specially, so reject it explicitly.
    if not K.vertices():
        return (False, "empty_complex")

    # These theorem-based terminal cases certify ordinary non-evasiveness.
    # Protected vertices remain an ordering preference for states that require
    # search; terminal theorems are independent of the ordering policy.
    if is_simplex(K):
        return (True, "simplex")

    if K.cone_vertices():
        return (True, "cone")

    # Non-evasiveness for a one-dimensional complex is exactly the tree test.
    if K.dimension() == 1:
        if is_tree_complex(K):
            return (True, "tree")
        return (False, "one_dimensional_not_tree")

    # Non-evasive complexes are contractible. Apply increasingly expensive
    # necessary conditions before starting any recursive branching.
    if not K.is_connected():
        return (False, "disconnected")

    if K.euler_characteristic() != 1:
        return (False, "euler_characteristic_not_one")

    # The time limit is cooperative: check immediately before a potentially
    # expensive homology call. A single Sage operation already in progress is
    # not forcibly interrupted.
    enforce_search_time_limit()
    homology_test = homology_test_for_state(K, depth, is_link_state)
    if homology_test is None:
        search_stats.homology_skipped += 1
    else:
        base_ring, ring_name = homology_test
        if not has_trivial_reduced_homology(
            K, base_ring, ring_name, depth=depth
        ):
            return (False, f"nontrivial_homology_{ring_name}")

    return (None, None)

def find_nonevasive_witness(
    root_K,
    root_bitset,
    witness_cache,
    certificate_store,
    vertex_bits,
    strategy="random",
    rng=None,
    root_distances=None,
    state_key=(int(0), int(0)),
    depth=0,
    is_link_state=False,
):
    """Cache verdicts under compact link/deletion histories.

    ``_NO_WINNING_VERTEX`` marks a terminal theorem/base case. Recursive
    successes store the vertex whose deletion and link both succeeded.

    ``is_link_state`` only schedules an optional GF(2) rejection screen. It
    cannot certify success, so it does not belong in the exact cache key.

    A state key is ``(linked_mask, deleted_mask)`` relative to this run's fixed
    root complex. Links and deletions at distinct vertices commute, so the two
    sets determine the resulting state exactly. Different histories can
    occasionally produce the same complex under different keys; that only
    misses a cache-sharing opportunity and cannot produce a false cache hit.
    """
    search_stats.recursive_calls += 1
    search_stats.deepest_path = max(search_stats.deepest_path, depth)
    enforce_search_time_limit()

    cached = witness_cache.lookup(state_key)
    if cached is not _CACHE_MISS:
        search_stats.cache_hits += 1
        return cached[0]

    enforce_search_state_limit_before_miss()
    search_stats.subcomplexes_examined += 1
    K = materialize_search_state(root_K, root_bitset, state_key)
    enforce_search_time_limit()
    terminal_result, terminal_reason = classify_nonevasive_state(
        K, depth=depth, is_link_state=is_link_state
    )
    if terminal_result is not None:
        # This is a leaf of the uncached search tree: a theorem/base success
        # or a topological rejection, rather than a memoized return.
        search_stats.terminal_states_classified += 1
        witness_cache.store(
            state_key, terminal_result, _NO_WINNING_VERTEX
        )
        certificate_store.store_terminal(
            state_key, terminal_result, terminal_reason
        )
        return terminal_result

    enforce_search_time_limit()
    vertices = get_vertices_by_strategy(
        K,
        strategy,
        rng=rng,
        root_distances=root_distances,
    )
    enforce_search_time_limit()
    failed_children = []
    for v in vertices:
        enforce_search_time_limit()
        search_stats.vertex_attempts += 1
        log_heartbeat("running")

        linked_mask, deleted_mask = state_key
        vertex_bit = vertex_bits[v]
        if linked_mask & deleted_mask:
            raise RuntimeError("Linked and deleted vertex masks overlap")
        if (linked_mask | deleted_mask) & vertex_bit:
            raise RuntimeError("A decided vertex was selected again")

        # Both children must be non-evasive. Test the normally much smaller
        # link first so a failed link avoids the expensive deletion subtree.
        link_state_key = (linked_mask | vertex_bit, deleted_mask)
        search_stats.link_recursive_calls += 1
        if not find_nonevasive_witness(
            root_K,
            root_bitset,
            witness_cache,
            certificate_store,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=link_state_key,
            depth=depth + 1,
            is_link_state=True,
        ):
            search_stats.link_first_rejections += 1
            failed_children.append(
                {"vertex": v, "branch": "link", "child": link_state_key}
            )
            continue

        deletion_state_key = (linked_mask, deleted_mask | vertex_bit)
        search_stats.deletion_recursive_calls += 1
        if not find_nonevasive_witness(
            root_K,
            root_bitset,
            witness_cache,
            certificate_store,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=deletion_state_key,
            depth=depth + 1,
            is_link_state=False,
        ):
            failed_children.append(
                {
                    "vertex": v,
                    "branch": "deletion",
                    "child": deletion_state_key,
                }
            )
            continue

        witness_cache.store(state_key, True, v)
        certificate_store.store_success(
            state_key,
            v,
            deletion_state_key,
            link_state_key,
        )
        return True

    witness_cache.store(state_key, False, _NO_WINNING_VERTEX)
    certificate_store.store_failure(state_key, failed_children)
    return False

def is_nonevasive(
    K,
    strategy="random",
    rng=None,
):
    search_stats.reset(len(K.vertices()), strategy)
    root_bitset = RootBitsetComplex(
        canonical_facets(K),
        vertex_order=[int(vertex) for vertex in K.vertices()],
    )
    vertex_bits = root_bitset.vertex_bits
    witness_cache = WitnessCache()
    certificate_store = CertificateStore()
    root_state_key = (int(0), int(0))
    log_heartbeat("running", force=True)
    root_distances = (
        build_root_distances(K) if strategy == "outer_layer" else None
    )

    resource_limit = None
    try:
        verdict = find_nonevasive_witness(
            K,
            root_bitset,
            witness_cache,
            certificate_store,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=root_state_key,
        )
    except SearchResourceLimitReached as exc:
        verdict = None
        resource_limit = exc
    else:
        search_stats.phase = "search_complete"
    return (verdict, certificate_store, vertex_bits, resource_limit)


def serialize_certificate_state(state_key, record):
    linked_mask, deleted_mask = state_key
    serialized = {
        "id": certificate_state_id(state_key),
        "linked_mask": hex(linked_mask),
        "deleted_mask": hex(deleted_mask),
        "verdict": record["verdict"],
    }
    if "terminal_reason" in record:
        serialized["terminal_reason"] = record["terminal_reason"]
    elif record["verdict"] == RESULT_NON_EVASIVE:
        serialized.update(
            {
                "winning_vertex": record["winning_vertex"],
                "deletion_child": certificate_state_id(
                    record["deletion_child"]
                ),
                "link_child": certificate_state_id(record["link_child"]),
            }
        )
    else:
        serialized["failed_children"] = [
            {
                "vertex": failure["vertex"],
                "branch": failure["branch"],
                "child": certificate_state_id(failure["child"]),
            }
            for failure in record["failed_children"]
        ]
    return serialized


def build_certificate_document(
    K, vertex_bits, certificate_kind, result, states
):
    vertex_order = [
        int(vertex)
        for vertex in sorted(vertex_bits, key=lambda item: vertex_bits[item])
    ]
    return {
        "format": "simplicial_nonevasiveness_certificate",
        "schema_version": int(1),
        "certificate_kind": certificate_kind,
        "result": result,
        "root_state": certificate_state_id((int(0), int(0))),
        "input": {
            "canonical_facets_sha256": canonical_complex_sha256(K),
            "facet_count": len(K.facets()),
            "vertex_count": len(K.vertices()),
            "vertex_order": vertex_order,
            "source": str(facets_file),
        },
        "run": {
            "knot_name": knot_name,
            "seed": int(seed),
            "strategy": search_stats.strategy,
            "state_engine": STATE_ENGINE,
            "search_state_limit": int(SEARCH_STATE_LIMIT),
            "search_time_limit_seconds": float(
                SEARCH_TIME_LIMIT_SECONDS
            ),
            "protected_vertices": sorted(PROTECTED_VERTICES),
            "protected_vertex_policy": PROTECTED_VERTEX_POLICY,
            "git_revision": current_git_revision(),
            "sage_version": current_sage_version(),
        },
        "states": states,
    }


def build_nonevasive_certificate(K, certificate_store, vertex_bits):
    """Build the reachable positive proof DAG rooted at the initial state."""
    root_state_key = (int(0), int(0))
    pending = [root_state_key]
    visited = set()
    states = []

    while pending:
        state_key = pending.pop()
        if state_key in visited:
            continue
        visited.add(state_key)
        record = certificate_store.get(state_key)
        if record["verdict"] != RESULT_NON_EVASIVE:
            raise RuntimeError(
                "A non-evasive certificate references an evasive state"
            )
        states.append(serialize_certificate_state(state_key, record))
        if "terminal_reason" not in record:
            pending.append(record["deletion_child"])
            pending.append(record["link_child"])

    states.sort(key=lambda state: state["id"])
    return build_certificate_document(
        K,
        vertex_bits,
        "non_evasive",
        RESULT_NON_EVASIVE,
        states,
    )


def build_evasive_certificate(K, certificate_store, vertex_bits):
    """Build the reachable negative proof DAG rooted at the initial state."""
    root_state_key = (int(0), int(0))
    pending = [root_state_key]
    visited = set()
    states = []

    while pending:
        state_key = pending.pop()
        if state_key in visited:
            continue
        visited.add(state_key)
        record = certificate_store.get(state_key)
        if record["verdict"] != RESULT_EVASIVE_CERTIFIED:
            raise RuntimeError(
                "An evasiveness certificate references a non-evasive state"
            )
        states.append(serialize_certificate_state(state_key, record))
        if "terminal_reason" not in record:
            pending.extend(
                failure["child"]
                for failure in record["failed_children"]
            )

    states.sort(key=lambda state: state["id"])
    return build_certificate_document(
        K,
        vertex_bits,
        "evasive",
        RESULT_EVASIVE_CERTIFIED,
        states,
    )


def write_certificate(document, path):
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_name(output_path.name + ".tmp")
    try:
        with temporary_path.open("w", encoding="utf-8") as output_file:
            json.dump(document, output_file, indent=2, sort_keys=True)
            output_file.write("\n")
        os.replace(temporary_path, output_path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()
    return output_path


# Run the test
start_time = time.time()
print(f"Using Seed: {seed}", flush=True)
print(f"State engine: {STATE_ENGINE}", flush=True)
rng = random.Random(seed)
(
    search_succeeded,
    certificate_store,
    vertex_bits,
    resource_limit,
) = is_nonevasive(K, strategy="random", rng=rng)
print("\n" + "="*50, flush=True)
if resource_limit is not None:
    final_result = RESULT_INCONCLUSIVE_RESOURCE_LIMIT
    print(
        "⚠️ The search reached a configured resource limit. "
        "No mathematical conclusion was drawn.",
        flush=True,
    )
    print(f"Resource limit reached: {resource_limit.kind}", flush=True)
elif search_succeeded:
    final_result = RESULT_NON_EVASIVE
    root_record = certificate_store.get((int(0), int(0)))
    print(
        "✅ The complex is non-evasive. Found a valid certificate DAG.",
        flush=True,
    )
    if "terminal_reason" in root_record:
        print(
            f"Root terminal reason: {root_record['terminal_reason']}",
            flush=True,
        )
    else:
        print(
            f"Root decision vertex: {root_record['winning_vertex']}",
            flush=True,
        )
else:
    if (
        PROTECTED_VERTEX_POLICY == "restrict"
        and search_stats.restricted_vertices_skipped > 0
    ):
        final_result = RESULT_INCONCLUSIVE_RESTRICTED
        print(
            "⚠️ No witness was found under the strict protected-vertex "
            "policy. Ordinary evasiveness was not proved.",
            flush=True,
        )
    else:
        final_result = RESULT_EVASIVE_CERTIFIED
        print(
            "❌ The unrestricted recursive search classified the "
            "complex as evasive.",
            flush=True,
        )

certificate_path = None
if final_result == RESULT_NON_EVASIVE:
    certificate_document = build_nonevasive_certificate(
        K, certificate_store, vertex_bits
    )
    certificate_path = write_certificate(
        certificate_document, CERTIFICATE_OUTPUT
    )
    print(f"Certificate: {certificate_path}", flush=True)
    print(
        f"Certificate DAG states: {len(certificate_document['states']):,}",
        flush=True,
    )
elif final_result == RESULT_EVASIVE_CERTIFIED:
    certificate_document = build_evasive_certificate(
        K, certificate_store, vertex_bits
    )
    certificate_path = write_certificate(
        certificate_document, CERTIFICATE_OUTPUT
    )
    print(f"Certificate: {certificate_path}", flush=True)
    print(
        f"Certificate DAG states: {len(certificate_document['states']):,}",
        flush=True,
    )
else:
    print(
        f"Certificate: not emitted for {final_result}",
        flush=True,
    )

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
print(
    f"Recursive child calls: {search_stats.link_recursive_calls:,} link / "
    f"{search_stats.deletion_recursive_calls:,} deletion",
    flush=True,
)
print(
    f"Vertices rejected by link-first: "
    f"{search_stats.link_first_rejections:,}",
    flush=True,
)
print(
    f"Sage state materializations: "
    f"{search_stats.sage_state_materializations:,}",
    flush=True,
)
print(
    f"Bitset state reconstructions: "
    f"{search_stats.bitset_state_reconstructions:,}",
    flush=True,
)
print(
    f"Configured limits: states={SEARCH_STATE_LIMIT:,}; "
    f"seconds={SEARCH_TIME_LIMIT_SECONDS:g}",
    flush=True,
)
print(
    f"Resource limit reached: "
    f"{search_stats.resource_limit_kind or 'none'}",
    flush=True,
)
print(
    f"Protected candidates skipped by strict policy: "
    f"{search_stats.restricted_vertices_skipped:,}",
    flush=True,
)
print(
    f"Homology ZZ: {search_stats.homology_zz_calls:,} calls, "
    f"{search_stats.homology_zz_rejections:,} rejections, "
    f"{search_stats.homology_zz_seconds:,.3f} seconds",
    flush=True,
)
print(
    f"Homology GF(2): {search_stats.homology_gf2_calls:,} calls, "
    f"{search_stats.homology_gf2_rejections:,} rejections, "
    f"{search_stats.homology_gf2_seconds:,.3f} seconds",
    flush=True,
)
print(
    f"Homology skipped at eligible nonterminal states: "
    f"{search_stats.homology_skipped:,}",
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
    f"cache_evictions={search_stats.cache_evictions}; "
    f"state_engine={STATE_ENGINE}; "
    f"elapsed_seconds={elapsed:.6f}; "
    f"peak_rss_mib={peak_rss_mib:.3f}; "
    f"recursive_calls={search_stats.recursive_calls}; "
    f"sage_state_materializations="
    f"{search_stats.sage_state_materializations}; "
    f"search_state_limit={SEARCH_STATE_LIMIT}; "
    f"search_time_limit_seconds={SEARCH_TIME_LIMIT_SECONDS:g}; "
    f"resource_limit="
    f"{search_stats.resource_limit_kind or 'none'}; "
    f"link_first_rejections={search_stats.link_first_rejections}; "
    f"protected_vertex_policy={PROTECTED_VERTEX_POLICY}; "
    f"restricted_vertices_skipped="
    f"{search_stats.restricted_vertices_skipped}; "
    f"homology_zz_calls={search_stats.homology_zz_calls}; "
    f"homology_gf2_calls={search_stats.homology_gf2_calls}",
    flush=True,
)
print(pretty_time, flush=True)
search_stats.phase = "completed"
log_heartbeat(
    "completed", result=final_result, elapsed_seconds=float(elapsed)
)
