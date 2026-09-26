"""Version 12 of the exact non-evasiveness search.

Protected vertices are a complete, soft ordering preference by default. The
historical hard restriction remains available explicitly, but a failed
restricted search is reported as inconclusive rather than evasive.
"""

import random
import time
import resource
import ast, hashlib, json, math, os, signal, subprocess, sys
from datetime import datetime, timedelta, UTC
from sage.all import GF, RR, ZZ
from sage.topology.simplicial_complex import SimplicialComplex
from pathlib import Path
from collections import Counter, OrderedDict, deque

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

from simplicial_bitset import (
    RootBitsetComplex,
    classify_facets_cheaply,
    delete_vertex_from_facets,
    facet_complex_has_free_face,
    link_vertex_from_facets,
    order_obstruction_names,
    vertices_mask,
)
from simplicial_isomorphism import (
    automorphism_vertex_orbits,
    canonical_incidence_key,
    canonical_map_inverse,
    vertex_isomorphism,
)

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
RESULT_INCONCLUSIVE_INTERRUPTED = "INCONCLUSIVE_INTERRUPTED"

CHECKPOINT_FORMAT = "simplicial_nonevasiveness_search_checkpoint"
CHECKPOINT_SCHEMA_VERSION = int(1)


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
NORMALIZED_CACHE_MAX_FAILURES = int(
    os.environ.get("NORMALIZED_CACHE_MAX_FAILURES", "100000")
)
ISOMORPHISM_CACHE_MAX_FAILURES = int(
    os.environ.get("ISOMORPHISM_CACHE_MAX_FAILURES", "100000")
)
STATE_ENGINE = os.environ.get("STATE_ENGINE", "bitset").strip().lower()
VALID_STATE_ENGINES = frozenset({"bitset", "sage_reference"})
if STATE_ENGINE not in VALID_STATE_ENGINES:
    raise ValueError("STATE_ENGINE must be one of: bitset, sage_reference")
SEARCH_STRATEGY = os.environ.get(
    "SEARCH_STRATEGY", "random"
).strip().lower()
VALID_SEARCH_STRATEGIES = frozenset(
    {
        "greedy",
        "outer_layer",
        "random",
        "max_degree",
        "lexical",
        "reverse_lexical",
        "exhaustive",
    }
)
if SEARCH_STRATEGY not in VALID_SEARCH_STRATEGIES:
    raise ValueError(
        "SEARCH_STRATEGY must be one of: "
        + ", ".join(sorted(VALID_SEARCH_STRATEGIES))
    )
CHILD_AWARE_MAX_VERTICES = int(
    os.environ.get("CHILD_AWARE_MAX_VERTICES", "80")
)
CHILD_AWARE_MAX_FACETS = int(
    os.environ.get("CHILD_AWARE_MAX_FACETS", "500")
)
SEARCH_STATE_LIMIT = int(os.environ.get("SEARCH_STATE_LIMIT", "0"))
SEARCH_TIME_LIMIT_SECONDS = float(
    os.environ.get("SEARCH_TIME_LIMIT_SECONDS", "0")
)
SEARCH_MEMORY_LIMIT_MIB = float(
    os.environ.get("SEARCH_MEMORY_LIMIT_MIB", "0")
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
if (
    not math.isfinite(SEARCH_MEMORY_LIMIT_MIB)
    or SEARCH_MEMORY_LIMIT_MIB < 0
):
    raise ValueError(
        "SEARCH_MEMORY_LIMIT_MIB must be a finite nonnegative number"
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


NORMALIZED_COMPLEX_CACHE = get_boolean_environment_setting(
    "NORMALIZED_COMPLEX_CACHE", True
)
ISOMORPHISM_COMPLEX_CACHE = get_boolean_environment_setting(
    "ISOMORPHISM_COMPLEX_CACHE", False
)
AUTOMORPHISM_ORBIT_PRUNING = get_boolean_environment_setting(
    "AUTOMORPHISM_ORBIT_PRUNING", False
)
CHILD_AWARE_ORDERING = get_boolean_environment_setting(
    "CHILD_AWARE_ORDERING", False
)

OBSTRUCTION_SCHEDULER = os.environ.get(
    "OBSTRUCTION_SCHEDULER", "fixed"
).strip().lower()
VALID_OBSTRUCTION_SCHEDULERS = frozenset({"fixed", "adaptive"})
if OBSTRUCTION_SCHEDULER not in VALID_OBSTRUCTION_SCHEDULERS:
    raise ValueError(
        "OBSTRUCTION_SCHEDULER must be one of: adaptive, fixed"
    )
OBSTRUCTION_ADAPTIVE_WARMUP_CALLS = int(
    os.environ.get("OBSTRUCTION_ADAPTIVE_WARMUP_CALLS", "8")
)
NONCOLLAPSIBILITY_OBSTRUCTION = get_boolean_environment_setting(
    "NONCOLLAPSIBILITY_OBSTRUCTION", False
)
NONCOLLAPSIBILITY_MAX_VERTICES = int(
    os.environ.get("NONCOLLAPSIBILITY_MAX_VERTICES", "80")
)
NONCOLLAPSIBILITY_MAX_FACETS = int(
    os.environ.get("NONCOLLAPSIBILITY_MAX_FACETS", "200")
)


def is_small_prime(value):
    """Return whether ``value`` is prime within the supported small range."""
    if value < 2 or value > 97:
        return False
    divisor = 2
    while divisor * divisor <= value:
        if value % divisor == 0:
            return False
        divisor += 1
    return True


def load_homology_field_primes(raw_value):
    """Parse a comma-separated list of distinct primes at most 97."""
    if raw_value is None:
        raw_value = "2"
    text = raw_value.strip()
    if not text:
        return tuple()
    try:
        primes = tuple(int(item.strip()) for item in text.split(","))
    except ValueError as exc:
        raise ValueError(
            "HOMOLOGY_FIELD_PRIMES must be comma-separated integers"
        ) from exc
    if len(set(primes)) != len(primes):
        raise ValueError("HOMOLOGY_FIELD_PRIMES cannot repeat a prime")
    if any(not is_small_prime(prime) for prime in primes):
        raise ValueError(
            "HOMOLOGY_FIELD_PRIMES must contain primes between 2 and 97"
        )
    return primes


# Homology eligibility policy. Integral homology is always used at the root
# after cheaper terminal tests unless an optional field screen rejects first.
# A descendant is considered small when it meets either enabled ZZ threshold.
# Larger direct-link states and periodic depth checkpoints receive the
# configured small-prime field screens instead.
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
if "HOMOLOGY_FIELDS_ON_LINKS" in os.environ:
    HOMOLOGY_FIELDS_ON_LINKS = get_boolean_environment_setting(
        "HOMOLOGY_FIELDS_ON_LINKS", True
    )
else:
    # Backward-compatible alias retained for existing v12 deployments.
    HOMOLOGY_FIELDS_ON_LINKS = get_boolean_environment_setting(
        "HOMOLOGY_GF2_ON_LINKS", True
    )
HOMOLOGY_FIELD_PRIMES = load_homology_field_primes(
    os.environ.get("HOMOLOGY_FIELD_PRIMES")
)
HOMOLOGY_FIELDS_AT_ROOT = get_boolean_environment_setting(
    "HOMOLOGY_FIELDS_AT_ROOT", False
)
HOMOLOGY_FIELD_RINGS = {
    prime: GF(prime) for prime in HOMOLOGY_FIELD_PRIMES
}

CHECKPOINT_PATH_TEXT = os.environ.get("CHECKPOINT_PATH", "").strip()
CHECKPOINT_PATH = (
    Path(CHECKPOINT_PATH_TEXT) if CHECKPOINT_PATH_TEXT else None
)
CHECKPOINT_RESUME = get_boolean_environment_setting(
    "CHECKPOINT_RESUME", False
)
CHECKPOINT_OVERWRITE = get_boolean_environment_setting(
    "CHECKPOINT_OVERWRITE", False
)
CHECKPOINT_INTERVAL_STATES = int(
    os.environ.get("CHECKPOINT_INTERVAL_STATES", "1000")
)
CHECKPOINT_INTERVAL_SECONDS = float(
    os.environ.get("CHECKPOINT_INTERVAL_SECONDS", "300")
)

if HEARTBEAT_INTERVAL_SECONDS <= 0:
    raise ValueError("HEARTBEAT_INTERVAL_SECONDS must be positive")

if WITNESS_CACHE_MAX_FAILURES < 0:
    raise ValueError("WITNESS_CACHE_MAX_FAILURES cannot be negative")

if NORMALIZED_CACHE_MAX_FAILURES < 0:
    raise ValueError("NORMALIZED_CACHE_MAX_FAILURES cannot be negative")

if ISOMORPHISM_CACHE_MAX_FAILURES < 0:
    raise ValueError("ISOMORPHISM_CACHE_MAX_FAILURES cannot be negative")

if CHILD_AWARE_MAX_VERTICES < 0:
    raise ValueError("CHILD_AWARE_MAX_VERTICES cannot be negative")

if CHILD_AWARE_MAX_FACETS < 0:
    raise ValueError("CHILD_AWARE_MAX_FACETS cannot be negative")

if OBSTRUCTION_ADAPTIVE_WARMUP_CALLS < 0:
    raise ValueError(
        "OBSTRUCTION_ADAPTIVE_WARMUP_CALLS cannot be negative"
    )

if NONCOLLAPSIBILITY_MAX_VERTICES < 0:
    raise ValueError("NONCOLLAPSIBILITY_MAX_VERTICES cannot be negative")

if NONCOLLAPSIBILITY_MAX_FACETS < 0:
    raise ValueError("NONCOLLAPSIBILITY_MAX_FACETS cannot be negative")

if HOMOLOGY_ZZ_MAX_VERTICES < 0:
    raise ValueError("HOMOLOGY_ZZ_MAX_VERTICES cannot be negative")

if HOMOLOGY_ZZ_MAX_FACES < 0:
    raise ValueError("HOMOLOGY_ZZ_MAX_FACES cannot be negative")

if HOMOLOGY_START_DEPTH < 0:
    raise ValueError("HOMOLOGY_START_DEPTH cannot be negative")

if HOMOLOGY_GF2_DEPTH_INTERVAL < 0:
    raise ValueError("HOMOLOGY_GF2_DEPTH_INTERVAL cannot be negative")

if CHECKPOINT_RESUME and CHECKPOINT_PATH is None:
    raise ValueError("CHECKPOINT_RESUME requires CHECKPOINT_PATH")

if CHECKPOINT_OVERWRITE and CHECKPOINT_RESUME:
    raise ValueError(
        "CHECKPOINT_OVERWRITE and CHECKPOINT_RESUME cannot both be true"
    )

if CHECKPOINT_INTERVAL_STATES < 0:
    raise ValueError("CHECKPOINT_INTERVAL_STATES cannot be negative")

if (
    not math.isfinite(CHECKPOINT_INTERVAL_SECONDS)
    or CHECKPOINT_INTERVAL_SECONDS < 0
):
    raise ValueError(
        "CHECKPOINT_INTERVAL_SECONDS must be a finite nonnegative number"
    )

# Only used when HEARTBEAT_MODE=file
HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE", f"/outputs/heartbeat_{knot_name}.log")

last_heartbeat = 0
checkpoint_interruption_signal = None
last_memory_limit_check_monotonic = 0.0

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


class SearchInterruptionRequested(RuntimeError):
    """Internal control flow for a signal-triggered checkpoint stop."""

    def __init__(self, signal_name):
        self.signal_name = str(signal_name)
        self.kind = "interruption_signal"
        self.configured_limit = None
        self.observed_value = self.signal_name
        super().__init__(f"interruption requested by {self.signal_name}")


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
        self.normalized_cache_hits = 0
        self.normalized_cache_entries = 0
        self.normalized_cache_peak_entries = 0
        self.normalized_cache_success_entries = 0
        self.normalized_cache_failure_entries = 0
        self.normalized_cache_evictions = 0
        self.normalized_key_computations = 0
        self.certificate_equivalence_aliases = 0
        self.isomorphism_cache_hits = 0
        self.isomorphism_cache_entries = 0
        self.isomorphism_cache_peak_entries = 0
        self.isomorphism_cache_success_entries = 0
        self.isomorphism_cache_failure_entries = 0
        self.isomorphism_cache_evictions = 0
        self.isomorphism_key_computations = 0
        self.certificate_isomorphism_aliases = 0
        self.automorphism_orbit_computations = 0
        self.automorphism_orbits = 0
        self.automorphism_vertices_pruned = 0
        self.certificate_orbit_automorphisms = 0
        self.child_aware_states_scored = 0
        self.child_aware_states_skipped = 0
        self.child_aware_candidates_scored = 0
        self.child_preclassifications = 0
        self.child_preclassified_positive = 0
        self.child_preclassified_negative = 0
        self.child_aware_states_reordered = 0
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
        self.homology_field_profiles = OrderedDict()
        self.obstruction_profiles = OrderedDict()
        self.obstruction_schedules = 0
        self.obstruction_reorders = 0
        self.noncollapsibility_states_eligible = 0
        self.noncollapsibility_states_skipped = 0
        self.checkpoint_writes = 0
        self.checkpoint_loaded_states = 0
        self.checkpoint_resume_count = 0
        self.checkpoint_prior_subcomplexes = 0
        self.restricted_vertices_skipped = 0

    def record_obstruction(self, name, elapsed_seconds, rejected):
        profile = self.obstruction_profiles.setdefault(
            name,
            {"calls": 0, "seconds": 0.0, "rejections": 0},
        )
        profile["calls"] += 1
        profile["seconds"] += float(elapsed_seconds)
        if rejected:
            profile["rejections"] += 1

    def record_field_homology(
        self, prime, elapsed_seconds, rejected
    ):
        profile = self.homology_field_profiles.setdefault(
            int(prime),
            {"calls": 0, "seconds": 0.0, "rejections": 0},
        )
        profile["calls"] += 1
        profile["seconds"] += float(elapsed_seconds)
        if rejected:
            profile["rejections"] += 1

    def update_cache_sizes(self, success_entries, failure_entries):
        self.cache_success_entries = int(success_entries)
        self.cache_failure_entries = int(failure_entries)
        self.cache_entries = int(success_entries + failure_entries)
        self.cache_peak_entries = max(
            self.cache_peak_entries, self.cache_entries
        )

    def update_normalized_cache_sizes(
        self, success_entries, failure_entries
    ):
        self.normalized_cache_success_entries = int(success_entries)
        self.normalized_cache_failure_entries = int(failure_entries)
        self.normalized_cache_entries = int(
            success_entries + failure_entries
        )
        self.normalized_cache_peak_entries = max(
            self.normalized_cache_peak_entries,
            self.normalized_cache_entries,
        )

    def update_isomorphism_cache_sizes(
        self, success_entries, failure_entries
    ):
        self.isomorphism_cache_success_entries = int(success_entries)
        self.isomorphism_cache_failure_entries = int(failure_entries)
        self.isomorphism_cache_entries = int(
            success_entries + failure_entries
        )
        self.isomorphism_cache_peak_entries = max(
            self.isomorphism_cache_peak_entries,
            self.isomorphism_cache_entries,
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

    def failure_state_keys(self):
        """Return failed exact-cache keys from oldest to newest."""
        return tuple(self._failures)


class NormalizedComplexCache:
    """Share completed verdicts for identical labeled facet-mask tuples."""

    def __init__(self, max_failures=NORMALIZED_CACHE_MAX_FAILURES):
        self.max_failures = int(max_failures)
        if self.max_failures < 0:
            raise ValueError("max_failures cannot be negative")
        self._successes = {}
        self._failures = OrderedDict()
        self._update_stats()

    def _update_stats(self):
        search_stats.update_normalized_cache_sizes(
            len(self._successes), len(self._failures)
        )

    def lookup(self, normalized_facets):
        success = self._successes.get(
            normalized_facets, _CACHE_MISS
        )
        if success is not _CACHE_MISS:
            representative_state, winning_vertex = success
            return (True, winning_vertex, representative_state)

        if normalized_facets in self._failures:
            representative_state = self._failures[normalized_facets]
            self._failures.move_to_end(normalized_facets)
            return (False, _NO_WINNING_VERTEX, representative_state)

        return _CACHE_MISS

    def store(
        self,
        normalized_facets,
        state_key,
        verdict,
        winning_vertex,
    ):
        if verdict:
            self._failures.pop(normalized_facets, None)
            self._successes[normalized_facets] = (
                state_key,
                winning_vertex,
            )
        elif self.max_failures:
            self._failures[normalized_facets] = state_key
            self._failures.move_to_end(normalized_facets)
            if len(self._failures) > self.max_failures:
                self._failures.popitem(last=False)
                search_stats.normalized_cache_evictions += 1
        self._update_stats()


class IsomorphismComplexCache:
    """Share verdicts across isomorphic vertex-facet incidence graphs."""

    def __init__(self, max_failures=ISOMORPHISM_CACHE_MAX_FAILURES):
        self.max_failures = int(max_failures)
        if self.max_failures < 0:
            raise ValueError("max_failures cannot be negative")
        self._successes = {}
        self._failures = OrderedDict()
        self._update_stats()

    def _update_stats(self):
        search_stats.update_isomorphism_cache_sizes(
            len(self._successes), len(self._failures)
        )

    @staticmethod
    def _make_hit(
        verdict,
        winning_vertex,
        representative_state,
        representative_canonical_to_label,
        current_label_to_canonical,
    ):
        isomorphism = vertex_isomorphism(
            current_label_to_canonical,
            representative_canonical_to_label,
        )
        if winning_vertex is _NO_WINNING_VERTEX:
            current_winning_vertex = _NO_WINNING_VERTEX
        else:
            representative_to_current = {
                target: source for source, target in isomorphism
            }
            current_winning_vertex = representative_to_current[
                winning_vertex
            ]
        return (
            verdict,
            current_winning_vertex,
            representative_state,
            isomorphism,
        )

    def lookup(self, canonical_key, current_label_to_canonical):
        success = self._successes.get(canonical_key, _CACHE_MISS)
        if success is not _CACHE_MISS:
            (
                representative_state,
                winning_vertex,
                representative_canonical_to_label,
            ) = success
            return self._make_hit(
                True,
                winning_vertex,
                representative_state,
                representative_canonical_to_label,
                current_label_to_canonical,
            )

        if canonical_key in self._failures:
            (
                representative_state,
                representative_canonical_to_label,
            ) = self._failures[canonical_key]
            self._failures.move_to_end(canonical_key)
            return self._make_hit(
                False,
                _NO_WINNING_VERTEX,
                representative_state,
                representative_canonical_to_label,
                current_label_to_canonical,
            )

        return _CACHE_MISS

    def store(
        self,
        canonical_key,
        label_to_canonical,
        state_key,
        verdict,
        winning_vertex,
    ):
        canonical_to_label = canonical_map_inverse(label_to_canonical)
        if verdict:
            self._failures.pop(canonical_key, None)
            self._successes[canonical_key] = (
                state_key,
                winning_vertex,
                canonical_to_label,
            )
        elif self.max_failures:
            self._failures[canonical_key] = (
                state_key,
                canonical_to_label,
            )
            self._failures.move_to_end(canonical_key)
            if len(self._failures) > self.max_failures:
                self._failures.popitem(last=False)
                search_stats.isomorphism_cache_evictions += 1
        self._update_stats()


class CertificateStore:
    """Retain proof records independently of cache eviction policy."""

    def __init__(self):
        self._records = {}

    def _store(self, state_key, record):
        existing = self._records.get(state_key)
        if existing is not None:
            if existing == record:
                return
            same_verdict = (
                existing.get("verdict") == record.get("verdict")
            )
            replaces_or_retains_alias = (
                "equivalent_state" in existing
                or "equivalent_state" in record
                or "isomorphic_state" in existing
                or "isomorphic_state" in record
            )
            if same_verdict and replaces_or_retains_alias:
                return
            raise RuntimeError(
                f"Conflicting certificate records for state {state_key}"
            )
        self._records[state_key] = record

    def store_equivalence(self, state_key, verdict, equivalent_state):
        self._store(
            state_key,
            {
                "verdict": (
                    RESULT_NON_EVASIVE if verdict
                    else RESULT_EVASIVE_CERTIFIED
                ),
                "equivalent_state": equivalent_state,
            },
        )

    def store_isomorphism(
        self,
        state_key,
        verdict,
        isomorphic_state,
        vertex_mapping,
    ):
        self._store(
            state_key,
            {
                "verdict": (
                    RESULT_NON_EVASIVE if verdict
                    else RESULT_EVASIVE_CERTIFIED
                ),
                "isomorphic_state": isomorphic_state,
                "vertex_isomorphism": tuple(vertex_mapping),
            },
        )

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
        serialized_failures = []
        for failure in failed_children:
            serialized_failure = {
                "vertex": int(failure["vertex"]),
                "branch": failure["branch"],
                "child": failure["child"],
            }
            if "orbit_members" in failure:
                serialized_failure["orbit_members"] = tuple(
                    int(member) for member in failure["orbit_members"]
                )
                serialized_failure["orbit_automorphisms"] = [
                    {
                        "target_vertex": int(item["target_vertex"]),
                        "vertex_isomorphism": tuple(
                            item["vertex_isomorphism"]
                        ),
                    }
                    for item in failure["orbit_automorphisms"]
                ]
            serialized_failures.append(serialized_failure)
        record = {
            "verdict": RESULT_EVASIVE_CERTIFIED,
            "failed_children": serialized_failures,
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

    def items(self):
        return tuple(self._records.items())

    def __len__(self):
        return len(self._records)


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
        "normalized_complex_cache": bool(NORMALIZED_COMPLEX_CACHE),
        "normalized_cache_max_failures": int(
            NORMALIZED_CACHE_MAX_FAILURES
        ),
        "search_state_limit": int(SEARCH_STATE_LIMIT),
        "search_time_limit_seconds": float(SEARCH_TIME_LIMIT_SECONDS),
        "search_memory_limit_mib": float(SEARCH_MEMORY_LIMIT_MIB),
        "checkpoint_enabled": bool(CHECKPOINT_PATH is not None),
        "checkpoint_path": (
            None if CHECKPOINT_PATH is None else str(CHECKPOINT_PATH)
        ),
        "checkpoint_resume_requested": bool(CHECKPOINT_RESUME),
        "checkpoint_interval_states": int(CHECKPOINT_INTERVAL_STATES),
        "checkpoint_interval_seconds": float(
            CHECKPOINT_INTERVAL_SECONDS
        ),
        "checkpoint_writes": int(search_stats.checkpoint_writes),
        "checkpoint_loaded_states": int(
            search_stats.checkpoint_loaded_states
        ),
        "checkpoint_resume_count": int(
            search_stats.checkpoint_resume_count
        ),
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
        "total_subcomplexes_examined": int(
            search_stats.checkpoint_prior_subcomplexes
            + search_stats.subcomplexes_examined
        ),
        "cache_misses": int(search_stats.subcomplexes_examined),
        "cache_hits": int(search_stats.cache_hits),
        "cache_entries": int(search_stats.cache_entries),
        "cache_peak_entries": int(search_stats.cache_peak_entries),
        "cache_success_entries": int(search_stats.cache_success_entries),
        "cache_failure_entries": int(search_stats.cache_failure_entries),
        "cache_failure_limit": int(WITNESS_CACHE_MAX_FAILURES),
        "cache_evictions": int(search_stats.cache_evictions),
        "cache_key_format": "linked_deleted_bitmasks",
        "normalized_cache_hits": int(
            search_stats.normalized_cache_hits
        ),
        "normalized_cache_entries": int(
            search_stats.normalized_cache_entries
        ),
        "normalized_cache_peak_entries": int(
            search_stats.normalized_cache_peak_entries
        ),
        "normalized_cache_success_entries": int(
            search_stats.normalized_cache_success_entries
        ),
        "normalized_cache_failure_entries": int(
            search_stats.normalized_cache_failure_entries
        ),
        "normalized_cache_evictions": int(
            search_stats.normalized_cache_evictions
        ),
        "normalized_key_computations": int(
            search_stats.normalized_key_computations
        ),
        "certificate_equivalence_aliases": int(
            search_stats.certificate_equivalence_aliases
        ),
        "normalized_cache_key_format": "labeled_maximal_facet_bitmasks",
        "isomorphism_complex_cache": bool(ISOMORPHISM_COMPLEX_CACHE),
        "isomorphism_cache_max_failures": int(
            ISOMORPHISM_CACHE_MAX_FAILURES
        ),
        "isomorphism_cache_hits": int(
            search_stats.isomorphism_cache_hits
        ),
        "isomorphism_cache_entries": int(
            search_stats.isomorphism_cache_entries
        ),
        "isomorphism_cache_peak_entries": int(
            search_stats.isomorphism_cache_peak_entries
        ),
        "isomorphism_cache_success_entries": int(
            search_stats.isomorphism_cache_success_entries
        ),
        "isomorphism_cache_failure_entries": int(
            search_stats.isomorphism_cache_failure_entries
        ),
        "isomorphism_cache_evictions": int(
            search_stats.isomorphism_cache_evictions
        ),
        "isomorphism_key_computations": int(
            search_stats.isomorphism_key_computations
        ),
        "certificate_isomorphism_aliases": int(
            search_stats.certificate_isomorphism_aliases
        ),
        "isomorphism_cache_key_format": (
            "colored_vertex_facet_incidence_canonical_graph"
        ),
        "automorphism_orbit_pruning": bool(
            AUTOMORPHISM_ORBIT_PRUNING
        ),
        "automorphism_orbit_computations": int(
            search_stats.automorphism_orbit_computations
        ),
        "automorphism_orbits": int(search_stats.automorphism_orbits),
        "automorphism_vertices_pruned": int(
            search_stats.automorphism_vertices_pruned
        ),
        "certificate_orbit_automorphisms": int(
            search_stats.certificate_orbit_automorphisms
        ),
        "child_aware_ordering": bool(CHILD_AWARE_ORDERING),
        "child_aware_max_vertices": int(CHILD_AWARE_MAX_VERTICES),
        "child_aware_max_facets": int(CHILD_AWARE_MAX_FACETS),
        "child_aware_states_scored": int(
            search_stats.child_aware_states_scored
        ),
        "child_aware_states_skipped": int(
            search_stats.child_aware_states_skipped
        ),
        "child_aware_candidates_scored": int(
            search_stats.child_aware_candidates_scored
        ),
        "child_preclassifications": int(
            search_stats.child_preclassifications
        ),
        "child_preclassified_positive": int(
            search_stats.child_preclassified_positive
        ),
        "child_preclassified_negative": int(
            search_stats.child_preclassified_negative
        ),
        "child_aware_states_reordered": int(
            search_stats.child_aware_states_reordered
        ),
        "obstruction_scheduler": OBSTRUCTION_SCHEDULER,
        "obstruction_adaptive_warmup_calls": int(
            OBSTRUCTION_ADAPTIVE_WARMUP_CALLS
        ),
        "obstruction_schedules": int(
            search_stats.obstruction_schedules
        ),
        "obstruction_reorders": int(search_stats.obstruction_reorders),
        "obstruction_profiles": {
            name: {
                "calls": int(profile["calls"]),
                "seconds": float(round(profile["seconds"], int(6))),
                "rejections": int(profile["rejections"]),
                "seconds_per_rejection": (
                    None
                    if not profile["rejections"]
                    else float(
                        round(
                            profile["seconds"] / profile["rejections"],
                            int(6),
                        )
                    )
                ),
            }
            for name, profile in search_stats.obstruction_profiles.items()
        },
        "noncollapsibility_obstruction": bool(
            NONCOLLAPSIBILITY_OBSTRUCTION
        ),
        "noncollapsibility_max_vertices": int(
            NONCOLLAPSIBILITY_MAX_VERTICES
        ),
        "noncollapsibility_max_facets": int(
            NONCOLLAPSIBILITY_MAX_FACETS
        ),
        "noncollapsibility_states_eligible": int(
            search_stats.noncollapsibility_states_eligible
        ),
        "noncollapsibility_states_skipped": int(
            search_stats.noncollapsibility_states_skipped
        ),
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
        "homology_policy": "scheduled_zz_small_fields",
        "homology_start_depth": int(HOMOLOGY_START_DEPTH),
        "homology_zz_max_vertices": int(HOMOLOGY_ZZ_MAX_VERTICES),
        "homology_zz_max_faces": int(HOMOLOGY_ZZ_MAX_FACES),
        "homology_gf2_depth_interval": int(
            HOMOLOGY_GF2_DEPTH_INTERVAL
        ),
        "homology_fields_on_links": bool(HOMOLOGY_FIELDS_ON_LINKS),
        "homology_gf2_on_links": bool(HOMOLOGY_FIELDS_ON_LINKS),
        "homology_field_primes": list(HOMOLOGY_FIELD_PRIMES),
        "homology_fields_at_root": bool(HOMOLOGY_FIELDS_AT_ROOT),
        "homology_field_profiles": {
            str(prime): {
                "calls": int(profile["calls"]),
                "seconds": float(round(profile["seconds"], int(6))),
                "rejections": int(profile["rejections"]),
            }
            for prime, profile in search_stats.homology_field_profiles.items()
        },
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


def child_order_category(link_verdict, deletion_verdict):
    """Rank exact cheap child outcomes for existential witness search."""
    if link_verdict is True and deletion_verdict is True:
        return 0
    if link_verdict is True and deletion_verdict is None:
        return 1
    if link_verdict is None and deletion_verdict is True:
        return 2
    if link_verdict is None and deletion_verdict is None:
        return 3
    if link_verdict is False:
        return 4
    if link_verdict is True:
        return 5
    return 6


def order_vertices_by_child_preclassification(
    vertices,
    normalized_facets,
    vertex_bits,
):
    """Stably prioritize candidates using exact, cheap bitset terminals."""
    vertices = list(vertices)
    current_vertex_count = vertices_mask(normalized_facets).bit_count()
    if (
        (
            CHILD_AWARE_MAX_VERTICES > 0
            and current_vertex_count > CHILD_AWARE_MAX_VERTICES
        )
        or (
            CHILD_AWARE_MAX_FACETS > 0
            and len(normalized_facets) > CHILD_AWARE_MAX_FACETS
        )
    ):
        search_stats.child_aware_states_skipped += 1
        return (vertices, {})

    search_stats.child_aware_states_scored += 1
    search_stats.child_aware_candidates_scored += len(vertices)
    previews = {}
    scored_vertices = []
    for base_index, vertex in enumerate(vertices):
        enforce_search_time_limit()
        vertex_bit = vertex_bits[vertex]
        link_facets = link_vertex_from_facets(
            normalized_facets, vertex_bit
        )
        deletion_facets = delete_vertex_from_facets(
            normalized_facets, vertex_bit
        )
        link_classification = classify_facets_cheaply(link_facets)
        deletion_classification = classify_facets_cheaply(
            deletion_facets
        )
        search_stats.child_preclassifications += 2
        for verdict, _reason in (
            link_classification,
            deletion_classification,
        ):
            if verdict is True:
                search_stats.child_preclassified_positive += 1
            elif verdict is False:
                search_stats.child_preclassified_negative += 1

        previews[vertex] = {
            "link_facets": link_facets,
            "deletion_facets": deletion_facets,
            "link_classification": link_classification,
            "deletion_classification": deletion_classification,
        }
        link_verdict = link_classification[0]
        deletion_verdict = deletion_classification[0]
        protected_rank = int(
            PROTECTED_VERTEX_POLICY == "prefer"
            and vertex in PROTECTED_VERTICES
        )
        score = (
            protected_rank,
            child_order_category(link_verdict, deletion_verdict),
            vertices_mask(link_facets).bit_count(),
            len(link_facets),
            vertices_mask(deletion_facets).bit_count(),
            len(deletion_facets),
            base_index,
        )
        scored_vertices.append((score, vertex))

    ordered_vertices = [
        vertex for _score, vertex in sorted(scored_vertices)
    ]
    if ordered_vertices != vertices:
        search_stats.child_aware_states_reordered += 1
    return (ordered_vertices, previews)


def homology_group_is_trivial(group, ring_name):
    """Handle Sage's different ZZ-group and field-vector-space results."""
    if ring_name == "ZZ":
        return len(group.invariants()) == 0
    return int(group.dimension()) == 0


def has_trivial_reduced_homology(
    K, base_ring, ring_name, depth=None
):
    """Run and time one sound homology rejection test."""
    field_prime = None
    if ring_name == "ZZ":
        search_stats.homology_zz_calls += 1
    else:
        field_prime = int(ring_name.removeprefix("GF"))
        if field_prime == 2:
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
        elif field_prime == 2:
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
        elif field_prime == 2:
            search_stats.homology_gf2_rejections += 1
    if field_prime is not None:
        search_stats.record_field_homology(
            field_prime, elapsed, not is_trivial
        )
    return is_trivial


def configured_field_homology_tests():
    return tuple(
        (HOMOLOGY_FIELD_RINGS[prime], f"GF{prime}")
        for prime in HOMOLOGY_FIELD_PRIMES
    )


def homology_tests_for_state(K, depth, is_link_state):
    """Choose the sound homology screens for this cache miss."""

    # Keep the one-time integral root check.
    if depth == 0:
        tests = []
        if HOMOLOGY_FIELDS_AT_ROOT:
            tests.extend(configured_field_homology_tests())
        tests.append((ZZ, "ZZ"))
        return tuple(tests)

    # Do not run descendant homology before the configured depth.
    # This also gates direct-link homology.
    if depth < HOMOLOGY_START_DEPTH:
        return tuple()

    vertex_count = len(K.vertices())

    # Use integral homology once the state is sufficiently small.
    if (
        HOMOLOGY_ZZ_MAX_VERTICES > 0
        and vertex_count <= HOMOLOGY_ZZ_MAX_VERTICES
    ):
        return ((ZZ, "ZZ"),)

    if HOMOLOGY_ZZ_MAX_FACES > 0:
        # f_vector()[0] is the empty face.
        nonempty_face_count = sum(
            int(n) for n in K.f_vector()[1:]
        )
        if nonempty_face_count <= HOMOLOGY_ZZ_MAX_FACES:
            return ((ZZ, "ZZ"),)

    # With start=200 and interval=20, checkpoints are
    # 200, 220, 240, ...
    is_checkpoint = (
        HOMOLOGY_GF2_DEPTH_INTERVAL > 0
        and (
            depth - HOMOLOGY_START_DEPTH
        ) % HOMOLOGY_GF2_DEPTH_INTERVAL == 0
    )

    if (HOMOLOGY_FIELDS_ON_LINKS and is_link_state) or is_checkpoint:
        return configured_field_homology_tests()

    return tuple()


def materialize_search_state(
    root_K, root_bitset, state_key, normalized_facets=None
):
    """Build one Sage state after a cache miss using the selected engine."""
    linked_mask, deleted_mask = state_key

    if STATE_ENGINE == "bitset":
        if normalized_facets is None:
            normalized_facets = root_bitset.state_facets(
                linked_mask, deleted_mask
            )
        state = root_bitset.sage_complex(normalized_facets)
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


def request_checkpoint_interruption(signal_number, _frame):
    global checkpoint_interruption_signal
    try:
        checkpoint_interruption_signal = signal.Signals(signal_number).name
    except ValueError:
        checkpoint_interruption_signal = str(signal_number)


def enforce_search_time_limit():
    """Cooperatively stop between operations for signals or resources."""
    global last_memory_limit_check_monotonic
    if checkpoint_interruption_signal is not None:
        search_stats.resource_limit_kind = "interruption_signal"
        search_stats.resource_limit_configured = None
        search_stats.resource_limit_observed = checkpoint_interruption_signal
        search_stats.phase = "interrupted"
        raise SearchInterruptionRequested(checkpoint_interruption_signal)

    # Reading /proc for every recursive call would distort the search. Check
    # at most every five seconds while retaining several GiB of headroom below
    # the batch container's hard memory ceiling.
    if SEARCH_MEMORY_LIMIT_MIB > 0:
        now_monotonic = time.monotonic()
        if (
            last_memory_limit_check_monotonic == 0
            or now_monotonic - last_memory_limit_check_monotonic >= 5.0
        ):
            last_memory_limit_check_monotonic = now_monotonic
            current_rss_mib, _peak_rss_mib = get_memory_usage_mib()
            if (
                current_rss_mib is not None
                and current_rss_mib >= SEARCH_MEMORY_LIMIT_MIB
            ):
                stop_for_resource_limit(
                    "memory_limit_mib",
                    float(SEARCH_MEMORY_LIMIT_MIB),
                    float(current_rss_mib),
                )

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


def noncollapsibility_obstruction_is_eligible(K, facet_masks):
    """Apply configured size gates to the exact no-free-face test."""
    if not NONCOLLAPSIBILITY_OBSTRUCTION:
        return False
    if (
        NONCOLLAPSIBILITY_MAX_VERTICES > 0
        and len(K.vertices()) > NONCOLLAPSIBILITY_MAX_VERTICES
    ):
        search_stats.noncollapsibility_states_skipped += 1
        return False
    facet_count = (
        len(facet_masks) if facet_masks is not None else len(K.facets())
    )
    if (
        NONCOLLAPSIBILITY_MAX_FACETS > 0
        and facet_count > NONCOLLAPSIBILITY_MAX_FACETS
    ):
        search_stats.noncollapsibility_states_skipped += 1
        return False
    search_stats.noncollapsibility_states_eligible += 1
    return True


def facet_masks_from_sage_complex(K):
    """Encode a standalone Sage complex for the free-face predicate."""
    vertex_bits = {
        vertex: int(1) << index
        for index, vertex in enumerate(K.vertices())
    }
    return tuple(
        sum(vertex_bits[vertex] for vertex in facet)
        for facet in K.facets()
    )


def run_profiled_obstruction(name, callback):
    """Run one sound negative test and record cost and rejection yield."""
    started_at = time.perf_counter()
    reason = None
    try:
        reason = callback()
        return reason
    finally:
        search_stats.record_obstruction(
            name,
            time.perf_counter() - started_at,
            reason is not None,
        )


def classify_nonevasive_state(
    K, depth=0, is_link_state=False, facet_masks=None
):
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

    # Non-evasive complexes are collapsible and therefore contractible. Every
    # test below is a one-sided rejection theorem. Adaptive mode changes only
    # their order, never their meaning or whether an eligible test is run.
    tests = [
        (
            "connectivity",
            lambda: None if K.is_connected() else "disconnected",
        ),
        (
            "euler_characteristic",
            lambda: (
                None
                if K.euler_characteristic() == 1
                else "euler_characteristic_not_one"
            ),
        ),
    ]

    if noncollapsibility_obstruction_is_eligible(K, facet_masks):
        if facet_masks is None:
            facet_masks = facet_masks_from_sage_complex(K)
        tests.append(
            (
                "no_free_face",
                lambda: (
                    None
                    if facet_complex_has_free_face(facet_masks)
                    else "no_free_face_noncollapsible"
                ),
            )
        )

    homology_tests = homology_tests_for_state(K, depth, is_link_state)
    if not homology_tests:
        search_stats.homology_skipped += 1
    for base_ring, ring_name in homology_tests:
        tests.append(
            (
                f"homology_{ring_name}",
                lambda base_ring=base_ring, ring_name=ring_name: (
                    None
                    if has_trivial_reduced_homology(
                        K, base_ring, ring_name, depth=depth
                    )
                    else f"nontrivial_homology_{ring_name}"
                ),
            )
        )

    fixed_names = tuple(name for name, _callback in tests)
    scheduled_names = order_obstruction_names(
        fixed_names,
        search_stats.obstruction_profiles,
        mode=("fixed" if depth == 0 else OBSTRUCTION_SCHEDULER),
        warmup_calls=OBSTRUCTION_ADAPTIVE_WARMUP_CALLS,
    )
    search_stats.obstruction_schedules += 1
    if scheduled_names != fixed_names:
        search_stats.obstruction_reorders += 1
    tests_by_name = dict(tests)

    for name in scheduled_names:
        # The time limit is cooperative: check immediately before each test.
        # A Sage operation already in progress is not forcibly interrupted.
        enforce_search_time_limit()
        rejection_reason = run_profiled_obstruction(
            name, tests_by_name[name]
        )
        if rejection_reason is not None:
            return (False, rejection_reason)

    return (None, None)


def failed_child_record(vertex, branch, child_state, orbit_record=None):
    record = {
        "vertex": int(vertex),
        "branch": branch,
        "child": child_state,
    }
    if orbit_record is not None:
        members = tuple(int(member) for member in orbit_record["members"])
        record["orbit_members"] = members
        record["orbit_automorphisms"] = [
            {
                "target_vertex": int(member),
                "vertex_isomorphism": tuple(
                    orbit_record["automorphisms"][member]
                ),
            }
            for member in members
            if member != vertex
        ]
        search_stats.certificate_orbit_automorphisms += len(
            record["orbit_automorphisms"]
        )
    return record


def find_nonevasive_witness(
    root_K,
    root_bitset,
    witness_cache,
    normalized_cache,
    isomorphism_cache,
    certificate_store,
    checkpoint_manager,
    vertex_bits,
    strategy="random",
    rng=None,
    root_distances=None,
    state_key=(int(0), int(0)),
    depth=0,
    is_link_state=False,
    precomputed_facets=None,
):
    """Cache verdicts under compact link/deletion histories.

    ``_NO_WINNING_VERTEX`` marks a terminal theorem/base case. Recursive
    successes store the vertex whose deletion and link both succeeded.

    ``is_link_state`` only schedules an optional GF(2) rejection screen. It
    cannot certify success, so it does not belong in the exact cache key.

    A state key is ``(linked_mask, deleted_mask)`` relative to this run's fixed
    root complex. Links and deletions at distinct vertices commute, so the two
    sets determine the resulting state exactly. The optional normalized cache
    additionally shares completed results when different state keys produce
    the exact same labeled facet-mask tuple.

    The optional isomorphism cache is consulted only after both exact caches.
    It canonically labels the colored vertex-facet incidence graph and stores
    an explicit label bijection for independent certificate verification.
    """
    search_stats.recursive_calls += 1
    search_stats.deepest_path = max(search_stats.deepest_path, depth)
    enforce_search_time_limit()

    cached = witness_cache.lookup(state_key)
    if cached is not _CACHE_MISS:
        search_stats.cache_hits += 1
        return cached[0]

    normalized_facets = precomputed_facets
    if (
        normalized_facets is None
        and (
            NORMALIZED_COMPLEX_CACHE
            or ISOMORPHISM_COMPLEX_CACHE
            or AUTOMORPHISM_ORBIT_PRUNING
            or CHILD_AWARE_ORDERING
            or NONCOLLAPSIBILITY_OBSTRUCTION
            or STATE_ENGINE == "bitset"
        )
    ):
        normalized_facets = root_bitset.state_facets(*state_key)

    if NORMALIZED_COMPLEX_CACHE:
        search_stats.normalized_key_computations += 1
        normalized_cached = normalized_cache.lookup(normalized_facets)
        if normalized_cached is not _CACHE_MISS:
            verdict, winning_vertex, representative_state = normalized_cached
            if representative_state == state_key:
                # The bounded exact failure LRU may evict this state while
                # the normalized cache still retains its completed result.
                # This is a direct memoized hit, not an equivalence edge: the
                # state's original proof record is already in the independent
                # certificate store.
                search_stats.normalized_cache_hits += 1
                witness_cache.store(state_key, verdict, winning_vertex)
                checkpoint_manager.maybe_write()
                enforce_search_time_limit()
                return verdict
            search_stats.normalized_cache_hits += 1
            search_stats.certificate_equivalence_aliases += 1
            witness_cache.store(state_key, verdict, winning_vertex)
            certificate_store.store_equivalence(
                state_key, verdict, representative_state
            )
            checkpoint_manager.maybe_write()
            enforce_search_time_limit()
            return verdict

    isomorphism_key = None
    label_to_canonical = None
    if ISOMORPHISM_COMPLEX_CACHE:
        search_stats.isomorphism_key_computations += 1
        isomorphism_key, label_to_canonical = canonical_incidence_key(
            normalized_facets,
            root_bitset.vertex_order,
            distinguished_vertices=(
                PROTECTED_VERTICES
                if PROTECTED_VERTEX_POLICY == "restrict"
                else ()
            ),
        )
        isomorphism_cached = isomorphism_cache.lookup(
            isomorphism_key, label_to_canonical
        )
        if isomorphism_cached is not _CACHE_MISS:
            (
                verdict,
                winning_vertex,
                representative_state,
                vertex_mapping,
            ) = isomorphism_cached
            if representative_state == state_key:
                # As above, an exact failure may have left the bounded LRU
                # while its isomorphism-class result and proof record remain.
                # Restore the exact cache without creating a self-alias.
                search_stats.isomorphism_cache_hits += 1
                witness_cache.store(state_key, verdict, winning_vertex)
                checkpoint_manager.maybe_write()
                enforce_search_time_limit()
                return verdict
            search_stats.isomorphism_cache_hits += 1
            search_stats.certificate_isomorphism_aliases += 1
            witness_cache.store(state_key, verdict, winning_vertex)
            certificate_store.store_isomorphism(
                state_key,
                verdict,
                representative_state,
                vertex_mapping,
            )
            checkpoint_manager.maybe_write()
            enforce_search_time_limit()
            return verdict

    enforce_search_state_limit_before_miss()
    search_stats.subcomplexes_examined += 1
    K = materialize_search_state(
        root_K,
        root_bitset,
        state_key,
        normalized_facets=normalized_facets,
    )
    enforce_search_time_limit()
    terminal_result, terminal_reason = classify_nonevasive_state(
        K,
        depth=depth,
        is_link_state=is_link_state,
        facet_masks=normalized_facets,
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
        if NORMALIZED_COMPLEX_CACHE:
            normalized_cache.store(
                normalized_facets,
                state_key,
                terminal_result,
                _NO_WINNING_VERTEX,
            )
        if ISOMORPHISM_COMPLEX_CACHE:
            isomorphism_cache.store(
                isomorphism_key,
                label_to_canonical,
                state_key,
                terminal_result,
                _NO_WINNING_VERTEX,
            )
        checkpoint_manager.maybe_write()
        return terminal_result

    enforce_search_time_limit()
    vertices = get_vertices_by_strategy(
        K,
        strategy,
        rng=rng,
        root_distances=root_distances,
    )
    enforce_search_time_limit()
    if CHILD_AWARE_ORDERING:
        vertices, child_previews = order_vertices_by_child_preclassification(
            vertices,
            normalized_facets,
            vertex_bits,
        )
    else:
        child_previews = {}
    enforce_search_time_limit()
    if AUTOMORPHISM_ORBIT_PRUNING:
        search_stats.automorphism_orbit_computations += 1
        orbit_records = automorphism_vertex_orbits(
            normalized_facets,
            root_bitset.vertex_order,
            candidate_vertices=vertices,
            distinguished_vertices=(
                PROTECTED_VERTICES
                if PROTECTED_VERTEX_POLICY == "restrict"
                else ()
            ),
        )
        search_stats.automorphism_orbits += len(orbit_records)
        search_stats.automorphism_vertices_pruned += (
            len(vertices) - len(orbit_records)
        )
    else:
        orbit_records = tuple(
            {
                "representative": vertex,
                "members": (vertex,),
                "automorphisms": {},
            }
            for vertex in vertices
        )
    failed_children = []
    for orbit_record in orbit_records:
        v = orbit_record["representative"]
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
            normalized_cache,
            isomorphism_cache,
            certificate_store,
            checkpoint_manager,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=link_state_key,
            depth=depth + 1,
            is_link_state=True,
            precomputed_facets=(
                child_previews.get(v, {}).get("link_facets")
            ),
        ):
            search_stats.link_first_rejections += 1
            failed_children.append(
                failed_child_record(
                    v,
                    "link",
                    link_state_key,
                    orbit_record=(
                        orbit_record
                        if AUTOMORPHISM_ORBIT_PRUNING
                        else None
                    ),
                )
            )
            continue

        deletion_state_key = (linked_mask, deleted_mask | vertex_bit)
        search_stats.deletion_recursive_calls += 1
        if not find_nonevasive_witness(
            root_K,
            root_bitset,
            witness_cache,
            normalized_cache,
            isomorphism_cache,
            certificate_store,
            checkpoint_manager,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=deletion_state_key,
            depth=depth + 1,
            is_link_state=False,
            precomputed_facets=(
                child_previews.get(v, {}).get("deletion_facets")
            ),
        ):
            failed_children.append(
                failed_child_record(
                    v,
                    "deletion",
                    deletion_state_key,
                    orbit_record=(
                        orbit_record
                        if AUTOMORPHISM_ORBIT_PRUNING
                        else None
                    ),
                )
            )
            continue

        certificate_store.store_success(
            state_key,
            v,
            deletion_state_key,
            link_state_key,
        )
        witness_cache.store(state_key, True, v)
        if NORMALIZED_COMPLEX_CACHE:
            normalized_cache.store(
                normalized_facets, state_key, True, v
            )
        if ISOMORPHISM_COMPLEX_CACHE:
            isomorphism_cache.store(
                isomorphism_key,
                label_to_canonical,
                state_key,
                True,
                v,
            )
        checkpoint_manager.maybe_write()
        return True

    certificate_store.store_failure(state_key, failed_children)
    witness_cache.store(state_key, False, _NO_WINNING_VERTEX)
    if NORMALIZED_COMPLEX_CACHE:
        normalized_cache.store(
            normalized_facets,
            state_key,
            False,
            _NO_WINNING_VERTEX,
        )
    if ISOMORPHISM_COMPLEX_CACHE:
        isomorphism_cache.store(
            isomorphism_key,
            label_to_canonical,
            state_key,
            False,
            _NO_WINNING_VERTEX,
        )
    checkpoint_manager.maybe_write()
    return False

def is_nonevasive(
    K,
    strategy="random",
    rng=None,
):
    global checkpoint_interruption_signal
    global last_memory_limit_check_monotonic
    checkpoint_interruption_signal = None
    last_memory_limit_check_monotonic = 0.0
    search_stats.reset(len(K.vertices()), strategy)
    root_bitset = RootBitsetComplex(
        canonical_facets(K),
        vertex_order=[int(vertex) for vertex in K.vertices()],
    )
    vertex_bits = root_bitset.vertex_bits
    witness_cache = WitnessCache()
    normalized_cache = NormalizedComplexCache()
    isomorphism_cache = IsomorphismComplexCache()
    certificate_store = CertificateStore()
    checkpoint_manager = CheckpointManager(
        K,
        vertex_bits,
        witness_cache,
        certificate_store,
        rng,
    )
    checkpoint_manager.load()
    root_state_key = (int(0), int(0))
    log_heartbeat("running", force=True)
    root_distances = (
        build_root_distances(K) if strategy == "outer_layer" else None
    )

    previous_signal_handlers = {}
    if checkpoint_manager.enabled:
        for signal_number in (signal.SIGINT, signal.SIGTERM):
            previous_signal_handlers[signal_number] = signal.getsignal(
                signal_number
            )
            signal.signal(signal_number, request_checkpoint_interruption)

    stop_reason = None
    try:
        verdict = find_nonevasive_witness(
            K,
            root_bitset,
            witness_cache,
            normalized_cache,
            isomorphism_cache,
            certificate_store,
            checkpoint_manager,
            vertex_bits,
            strategy=strategy,
            rng=rng,
            root_distances=root_distances,
            state_key=root_state_key,
        )
    except SearchResourceLimitReached as exc:
        verdict = None
        stop_reason = exc
        checkpoint_manager.write(
            "resource_limit",
            stop={
                "kind": exc.kind,
                "configured": exc.configured_limit,
                "observed": exc.observed_value,
            },
        )
    except SearchInterruptionRequested as exc:
        verdict = None
        stop_reason = exc
        checkpoint_manager.write(
            "interrupted",
            stop={"kind": exc.kind, "signal": exc.signal_name},
        )
    except BaseException as exc:
        try:
            checkpoint_manager.write(
                "error",
                stop={
                    "kind": type(exc).__name__,
                    "message": str(exc),
                },
            )
        except Exception as checkpoint_exc:
            print(
                f"Checkpoint write after error also failed: {checkpoint_exc}",
                flush=True,
            )
        raise
    else:
        search_stats.phase = "search_complete"
        if verdict:
            checkpoint_result = RESULT_NON_EVASIVE
        elif (
            PROTECTED_VERTEX_POLICY == "restrict"
            and search_stats.restricted_vertices_skipped > 0
        ):
            checkpoint_result = RESULT_INCONCLUSIVE_RESTRICTED
        else:
            checkpoint_result = RESULT_EVASIVE_CERTIFIED
        checkpoint_manager.write(
            "completed",
            stop={"result": checkpoint_result},
        )
    finally:
        for signal_number, previous_handler in previous_signal_handlers.items():
            signal.signal(signal_number, previous_handler)
    return (verdict, certificate_store, vertex_bits, stop_reason)


def serialize_certificate_state(state_key, record):
    linked_mask, deleted_mask = state_key
    serialized = {
        "id": certificate_state_id(state_key),
        "linked_mask": hex(linked_mask),
        "deleted_mask": hex(deleted_mask),
        "verdict": record["verdict"],
    }
    if "equivalent_state" in record:
        serialized["equivalent_state"] = certificate_state_id(
            record["equivalent_state"]
        )
    elif "isomorphic_state" in record:
        serialized["isomorphic_state"] = certificate_state_id(
            record["isomorphic_state"]
        )
        serialized["vertex_isomorphism"] = [
            {
                "source_vertex": source_vertex,
                "target_vertex": target_vertex,
            }
            for source_vertex, target_vertex
            in record["vertex_isomorphism"]
        ]
    elif "terminal_reason" in record:
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
        serialized_failures = []
        for failure in record["failed_children"]:
            serialized_failure = {
                "vertex": failure["vertex"],
                "branch": failure["branch"],
                "child": certificate_state_id(failure["child"]),
            }
            if "orbit_members" in failure:
                serialized_failure["orbit_members"] = list(
                    failure["orbit_members"]
                )
                serialized_failure["orbit_automorphisms"] = [
                    {
                        "target_vertex": item["target_vertex"],
                        "vertex_isomorphism": [
                            {
                                "source_vertex": source_vertex,
                                "target_vertex": target_vertex,
                            }
                            for source_vertex, target_vertex
                            in item["vertex_isomorphism"]
                        ],
                    }
                    for item in failure["orbit_automorphisms"]
                ]
            serialized_failures.append(serialized_failure)
        serialized["failed_children"] = serialized_failures
    return serialized


def checkpoint_hash_payload(payload):
    encoded = json.dumps(
        payload, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def checkpoint_json_safe(value):
    """Recursively convert Sage scalar/container values to JSON types."""
    if isinstance(value, dict):
        return {
            str(key): checkpoint_json_safe(item)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [checkpoint_json_safe(item) for item in value]
    if value is None or type(value) in {bool, int, float, str}:
        return value
    if isinstance(value, type(ZZ(0))):
        return int(value)
    if isinstance(value, type(RR(0))):
        return float(value)
    raise TypeError(
        f"Unsupported checkpoint JSON value: {type(value).__name__}"
    )


def checkpoint_implementation_record():
    source_paths = {
        "solver": Path(__file__).resolve(),
        "simplicial_bitset": SCRIPT_DIRECTORY / "simplicial_bitset.py",
        "simplicial_isomorphism": (
            SCRIPT_DIRECTORY / "simplicial_isomorphism.py"
        ),
    }
    source_hashes = {}
    for name, path in source_paths.items():
        try:
            source_hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as exc:
            raise RuntimeError(
                f"Cannot fingerprint checkpoint implementation file: {path}"
            ) from exc
    return {
        "source_sha256": source_hashes,
        "sage_version": current_sage_version(),
    }


def checkpoint_configuration_record():
    """Return settings that must remain identical across resume."""
    return {
        "seed": int(seed),
        "search_strategy": SEARCH_STRATEGY,
        "state_engine": STATE_ENGINE,
        "protected_vertices": sorted(PROTECTED_VERTICES),
        "protected_vertex_policy": PROTECTED_VERTEX_POLICY,
        "witness_cache_max_failures": int(WITNESS_CACHE_MAX_FAILURES),
        "normalized_complex_cache": bool(NORMALIZED_COMPLEX_CACHE),
        "normalized_cache_max_failures": int(
            NORMALIZED_CACHE_MAX_FAILURES
        ),
        "isomorphism_complex_cache": bool(ISOMORPHISM_COMPLEX_CACHE),
        "isomorphism_cache_max_failures": int(
            ISOMORPHISM_CACHE_MAX_FAILURES
        ),
        "automorphism_orbit_pruning": bool(
            AUTOMORPHISM_ORBIT_PRUNING
        ),
        "child_aware_ordering": bool(CHILD_AWARE_ORDERING),
        "child_aware_max_vertices": int(CHILD_AWARE_MAX_VERTICES),
        "child_aware_max_facets": int(CHILD_AWARE_MAX_FACETS),
        "obstruction_scheduler": OBSTRUCTION_SCHEDULER,
        "obstruction_adaptive_warmup_calls": int(
            OBSTRUCTION_ADAPTIVE_WARMUP_CALLS
        ),
        "noncollapsibility_obstruction": bool(
            NONCOLLAPSIBILITY_OBSTRUCTION
        ),
        "noncollapsibility_max_vertices": int(
            NONCOLLAPSIBILITY_MAX_VERTICES
        ),
        "noncollapsibility_max_facets": int(
            NONCOLLAPSIBILITY_MAX_FACETS
        ),
        "homology_zz_max_vertices": int(HOMOLOGY_ZZ_MAX_VERTICES),
        "homology_zz_max_faces": int(HOMOLOGY_ZZ_MAX_FACES),
        "homology_start_depth": int(HOMOLOGY_START_DEPTH),
        "homology_field_depth_interval": int(
            HOMOLOGY_GF2_DEPTH_INTERVAL
        ),
        "homology_fields_on_links": bool(HOMOLOGY_FIELDS_ON_LINKS),
        "homology_field_primes": list(HOMOLOGY_FIELD_PRIMES),
        "homology_fields_at_root": bool(HOMOLOGY_FIELDS_AT_ROOT),
    }


def checkpoint_input_record(K, vertex_bits):
    vertex_order = [
        int(vertex)
        for vertex in sorted(vertex_bits, key=lambda item: vertex_bits[item])
    ]
    return {
        "canonical_facets_sha256": canonical_complex_sha256(K),
        "facet_count": len(K.facets()),
        "vertex_count": len(K.vertices()),
        "vertex_order": vertex_order,
    }


def checkpoint_random_state_to_json(value):
    if isinstance(value, tuple):
        return [checkpoint_random_state_to_json(item) for item in value]
    return value


def checkpoint_random_state_from_json(value):
    if isinstance(value, list):
        return tuple(checkpoint_random_state_from_json(item) for item in value)
    return value


def checkpoint_state_key(record, vertex_count):
    try:
        linked_mask = int(record["linked_mask"], 0)
        deleted_mask = int(record["deleted_mask"], 0)
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("Checkpoint state masks must be hexadecimal strings") from exc
    if linked_mask < 0 or deleted_mask < 0:
        raise ValueError("Checkpoint state masks cannot be negative")
    if linked_mask & deleted_mask:
        raise ValueError("Checkpoint state masks overlap")
    if (linked_mask | deleted_mask) >> vertex_count:
        raise ValueError("Checkpoint state mask contains an unknown vertex")
    state_key = (linked_mask, deleted_mask)
    if record.get("id") != certificate_state_id(state_key):
        raise ValueError("Checkpoint state ID does not match its masks")
    return state_key


def deserialize_checkpoint_records(serialized_states, vertex_bits):
    if not isinstance(serialized_states, list):
        raise ValueError("Checkpoint states must be a list")
    id_to_key = {}
    keyed_records = []
    for serialized in serialized_states:
        if not isinstance(serialized, dict):
            raise ValueError("Malformed checkpoint state record")
        state_key = checkpoint_state_key(serialized, len(vertex_bits))
        identifier = serialized["id"]
        if identifier in id_to_key:
            raise ValueError(f"Duplicate checkpoint state: {identifier}")
        verdict = serialized.get("verdict")
        if verdict not in {RESULT_NON_EVASIVE, RESULT_EVASIVE_CERTIFIED}:
            raise ValueError("Checkpoint state has an invalid verdict")
        id_to_key[identifier] = state_key
        keyed_records.append((state_key, serialized))

    def referenced_state(identifier):
        if not isinstance(identifier, str) or identifier not in id_to_key:
            raise ValueError(
                f"Checkpoint references a missing state: {identifier}"
            )
        return id_to_key[identifier]

    records = []
    for state_key, serialized in keyed_records:
        verdict = serialized["verdict"]
        if "equivalent_state" in serialized:
            record = {
                "verdict": verdict,
                "equivalent_state": referenced_state(
                    serialized["equivalent_state"]
                ),
            }
        elif "isomorphic_state" in serialized:
            mapping = serialized.get("vertex_isomorphism")
            if not isinstance(mapping, list):
                raise ValueError(
                    "Checkpoint isomorphism requires a vertex mapping"
                )
            parsed_mapping = []
            for item in mapping:
                if not isinstance(item, dict) or set(item) != {
                    "source_vertex",
                    "target_vertex",
                }:
                    raise ValueError("Malformed checkpoint vertex mapping")
                source = item["source_vertex"]
                target = item["target_vertex"]
                if type(source) is not int or type(target) is not int:
                    raise ValueError(
                        "Checkpoint vertex mappings must use integers"
                    )
                parsed_mapping.append((source, target))
            record = {
                "verdict": verdict,
                "isomorphic_state": referenced_state(
                    serialized["isomorphic_state"]
                ),
                "vertex_isomorphism": tuple(parsed_mapping),
            }
        elif "terminal_reason" in serialized:
            reason = serialized["terminal_reason"]
            if not isinstance(reason, str) or not reason:
                raise ValueError("Invalid checkpoint terminal reason")
            record = {"verdict": verdict, "terminal_reason": reason}
        elif verdict == RESULT_NON_EVASIVE:
            winning_vertex = serialized.get("winning_vertex")
            if type(winning_vertex) is not int or winning_vertex not in vertex_bits:
                raise ValueError("Invalid checkpoint winning vertex")
            if (state_key[0] | state_key[1]) & vertex_bits[winning_vertex]:
                raise ValueError("Checkpoint winning vertex was already decided")
            record = {
                "verdict": verdict,
                "winning_vertex": winning_vertex,
                "deletion_child": referenced_state(
                    serialized.get("deletion_child")
                ),
                "link_child": referenced_state(serialized.get("link_child")),
            }
        else:
            serialized_failures = serialized.get("failed_children")
            if not isinstance(serialized_failures, list):
                raise ValueError("Checkpoint evasive state lacks failed children")
            failures = []
            for failure in serialized_failures:
                if not isinstance(failure, dict):
                    raise ValueError("Malformed checkpoint failed child")
                vertex = failure.get("vertex")
                branch = failure.get("branch")
                if type(vertex) is not int or vertex not in vertex_bits:
                    raise ValueError("Invalid checkpoint failed-child vertex")
                if branch not in {"link", "deletion"}:
                    raise ValueError("Invalid checkpoint failed-child branch")
                parsed_failure = {
                    "vertex": vertex,
                    "branch": branch,
                    "child": referenced_state(failure.get("child")),
                }
                if "orbit_members" in failure:
                    members = failure["orbit_members"]
                    automorphisms = failure.get("orbit_automorphisms")
                    if not isinstance(members, list) or not isinstance(
                        automorphisms, list
                    ):
                        raise ValueError("Malformed checkpoint orbit evidence")
                    parsed_failure["orbit_members"] = tuple(members)
                    parsed_automorphisms = []
                    for item in automorphisms:
                        if not isinstance(item, dict):
                            raise ValueError(
                                "Malformed checkpoint orbit automorphism"
                            )
                        parsed_automorphisms.append(
                            {
                                "target_vertex": item.get("target_vertex"),
                                "vertex_isomorphism": tuple(
                                    (
                                        mapping_item.get("source_vertex"),
                                        mapping_item.get("target_vertex"),
                                    )
                                    for mapping_item in item.get(
                                        "vertex_isomorphism", []
                                    )
                                ),
                            }
                        )
                    parsed_failure["orbit_automorphisms"] = (
                        parsed_automorphisms
                    )
                failures.append(parsed_failure)
            record = {"verdict": verdict, "failed_children": failures}
        records.append((state_key, record))
    return (records, id_to_key)


class CheckpointManager:
    """Atomically persist and restore completed exact-search states."""

    def __init__(
        self,
        K,
        vertex_bits,
        witness_cache,
        certificate_store,
        rng,
    ):
        self.enabled = CHECKPOINT_PATH is not None
        self.path = CHECKPOINT_PATH
        self.K = K
        self.vertex_bits = vertex_bits
        self.witness_cache = witness_cache
        self.certificate_store = certificate_store
        self.rng = rng
        self.resume_count = 0
        self.prior_subcomplexes = 0
        self.last_completed_count = len(certificate_store)
        self.last_write_monotonic = time.monotonic()
        self.owns_path = False
        if not self.enabled:
            return
        if CHECKPOINT_RESUME:
            if not self.path.is_file():
                raise FileNotFoundError(
                    f"Checkpoint file was not found: {self.path}"
                )
        elif self.path.exists() and not CHECKPOINT_OVERWRITE:
            raise FileExistsError(
                "Checkpoint already exists; set CHECKPOINT_RESUME=true, "
                "CHECKPOINT_OVERWRITE=true, or choose a new path: "
                f"{self.path}"
            )

    def load(self):
        if not self.enabled or not CHECKPOINT_RESUME:
            return
        try:
            with self.path.open(encoding="utf-8") as checkpoint_file:
                document = json.load(checkpoint_file)
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"Cannot read checkpoint: {self.path}") from exc
        if not isinstance(document, dict):
            raise ValueError("Checkpoint document must be an object")
        recorded_checksum = document.get("payload_sha256")
        payload = {
            key: value
            for key, value in document.items()
            if key != "payload_sha256"
        }
        if (
            not isinstance(recorded_checksum, str)
            or recorded_checksum != checkpoint_hash_payload(payload)
        ):
            raise ValueError("Checkpoint payload checksum does not match")
        if payload.get("format") != CHECKPOINT_FORMAT:
            raise ValueError("Unknown checkpoint format")
        if payload.get("schema_version") != CHECKPOINT_SCHEMA_VERSION:
            raise ValueError("Unsupported checkpoint schema version")
        if payload.get("status") not in {
            "running",
            "resource_limit",
            "interrupted",
            "completed",
            "error",
        }:
            raise ValueError("Checkpoint has an invalid status")

        expected_input = checkpoint_input_record(self.K, self.vertex_bits)
        if payload.get("input") != expected_input:
            raise ValueError("Checkpoint input complex does not match")
        expected_implementation = checkpoint_implementation_record()
        if payload.get("implementation") != expected_implementation:
            raise ValueError("Checkpoint implementation hash does not match")
        expected_configuration = checkpoint_configuration_record()
        actual_configuration = payload.get("configuration")
        if actual_configuration != expected_configuration:
            if isinstance(actual_configuration, dict):
                changed = sorted(
                    key
                    for key in set(actual_configuration) | set(expected_configuration)
                    if actual_configuration.get(key)
                    != expected_configuration.get(key)
                )
                detail = ", ".join(changed) or "unknown"
            else:
                detail = "configuration record"
            raise ValueError(
                f"Checkpoint search configuration does not match: {detail}"
            )

        progress = payload.get("progress")
        if not isinstance(progress, dict):
            raise ValueError("Checkpoint progress metadata is missing")
        records, id_to_key = deserialize_checkpoint_records(
            progress.get("states"), self.vertex_bits
        )
        for state_key, record in records:
            self.certificate_store._store(state_key, record)
            if record["verdict"] == RESULT_NON_EVASIVE:
                self.witness_cache.store(
                    state_key,
                    True,
                    record.get("winning_vertex", _NO_WINNING_VERTEX),
                )

        failure_lru = progress.get("failure_cache_lru")
        if not isinstance(failure_lru, list) or len(set(failure_lru)) != len(
            failure_lru
        ):
            raise ValueError("Checkpoint failure-cache LRU is malformed")
        if len(failure_lru) > WITNESS_CACHE_MAX_FAILURES:
            raise ValueError("Checkpoint failure-cache LRU exceeds its limit")
        records_by_key = dict(records)
        for identifier in failure_lru:
            if identifier not in id_to_key:
                raise ValueError(
                    "Checkpoint failure cache references a missing state"
                )
            state_key = id_to_key[identifier]
            if (
                records_by_key[state_key]["verdict"]
                != RESULT_EVASIVE_CERTIFIED
            ):
                raise ValueError(
                    "Checkpoint failure cache references a positive state"
                )
            self.witness_cache.store(
                state_key, False, _NO_WINNING_VERTEX
            )

        rng_state = progress.get("random_state")
        try:
            self.rng.setstate(checkpoint_random_state_from_json(rng_state))
        except (TypeError, ValueError) as exc:
            raise ValueError("Checkpoint random state is malformed") from exc

        prior_subcomplexes = progress.get("total_subcomplexes_examined")
        prior_resume_count = progress.get("resume_count")
        restricted_vertices_skipped = progress.get(
            "restricted_vertices_skipped"
        )
        if (
            type(prior_subcomplexes) is not int
            or prior_subcomplexes < 0
            or type(prior_resume_count) is not int
            or prior_resume_count < 0
            or type(restricted_vertices_skipped) is not int
            or restricted_vertices_skipped < 0
        ):
            raise ValueError("Checkpoint cumulative counters are malformed")
        self.prior_subcomplexes = prior_subcomplexes
        self.resume_count = prior_resume_count + 1
        search_stats.checkpoint_prior_subcomplexes = prior_subcomplexes
        search_stats.checkpoint_resume_count = self.resume_count
        search_stats.checkpoint_loaded_states = len(records)
        search_stats.restricted_vertices_skipped = (
            restricted_vertices_skipped
        )

        obstruction_profiles = progress.get("obstruction_profiles", {})
        field_profiles = progress.get("homology_field_profiles", {})
        if not isinstance(obstruction_profiles, dict) or not isinstance(
            field_profiles, dict
        ):
            raise ValueError("Checkpoint profiling records are malformed")
        search_stats.obstruction_profiles = OrderedDict(
            (name, dict(profile))
            for name, profile in obstruction_profiles.items()
        )
        search_stats.homology_field_profiles = OrderedDict(
            (int(prime), dict(profile))
            for prime, profile in field_profiles.items()
        )

        self.last_completed_count = len(self.certificate_store)
        self.last_write_monotonic = time.monotonic()
        self.owns_path = True
        print(
            f"Resumed checkpoint: {self.path} "
            f"({len(records):,} completed states; "
            f"status={payload['status']})",
            flush=True,
        )

    def _progress_record(self):
        serialized_states = [
            serialize_certificate_state(state_key, record)
            for state_key, record in self.certificate_store.items()
        ]
        serialized_states.sort(key=lambda record: record["id"])
        return {
            "states": serialized_states,
            "failure_cache_lru": [
                certificate_state_id(state_key)
                for state_key in self.witness_cache.failure_state_keys()
            ],
            "random_state": checkpoint_random_state_to_json(
                self.rng.getstate()
            ),
            "total_subcomplexes_examined": int(
                self.prior_subcomplexes
                + search_stats.subcomplexes_examined
            ),
            "resume_count": int(self.resume_count),
            "restricted_vertices_skipped": int(
                search_stats.restricted_vertices_skipped
            ),
            "obstruction_profiles": search_stats.obstruction_profiles,
            "homology_field_profiles": {
                str(prime): profile
                for prime, profile in search_stats.homology_field_profiles.items()
            },
        }

    def write(self, status, stop=None):
        if not self.enabled:
            return
        if status not in {
            "running",
            "resource_limit",
            "interrupted",
            "completed",
            "error",
        }:
            raise ValueError(f"Invalid checkpoint status: {status}")
        search_stats.checkpoint_writes += 1
        payload = checkpoint_json_safe({
            "format": CHECKPOINT_FORMAT,
            "schema_version": CHECKPOINT_SCHEMA_VERSION,
            "status": status,
            "timestamp": datetime.now(UTC).isoformat(),
            "input": checkpoint_input_record(self.K, self.vertex_bits),
            "implementation": checkpoint_implementation_record(),
            "configuration": checkpoint_configuration_record(),
            "resource_limits": {
                "search_state_limit": int(SEARCH_STATE_LIMIT),
                "search_time_limit_seconds": float(
                    SEARCH_TIME_LIMIT_SECONDS
                ),
                "search_memory_limit_mib": float(
                    SEARCH_MEMORY_LIMIT_MIB
                ),
            },
            "stop": stop,
            "progress": self._progress_record(),
        })
        document = dict(payload)
        document["payload_sha256"] = checkpoint_hash_payload(payload)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = self.path.with_name(self.path.name + ".tmp")
        try:
            with temporary_path.open("w", encoding="utf-8") as output_file:
                json.dump(document, output_file, indent=2, sort_keys=True)
                output_file.write("\n")
                output_file.flush()
                os.fsync(output_file.fileno())
            os.replace(temporary_path, self.path)
        finally:
            if temporary_path.exists():
                temporary_path.unlink()
        self.owns_path = True
        self.last_completed_count = len(self.certificate_store)
        self.last_write_monotonic = time.monotonic()
        print(
            f"Checkpoint written: {self.path} "
            f"({self.last_completed_count:,} completed states; "
            f"status={status})",
            flush=True,
        )

    def maybe_write(self):
        if not self.enabled:
            return
        completed_count = len(self.certificate_store)
        if completed_count <= self.last_completed_count:
            return
        states_due = (
            CHECKPOINT_INTERVAL_STATES > 0
            and completed_count - self.last_completed_count
            >= CHECKPOINT_INTERVAL_STATES
        )
        seconds_due = (
            CHECKPOINT_INTERVAL_SECONDS > 0
            and time.monotonic() - self.last_write_monotonic
            >= CHECKPOINT_INTERVAL_SECONDS
        )
        if states_due or seconds_due:
            self.write("running")


def build_certificate_document(
    K, vertex_bits, certificate_kind, result, states
):
    vertex_order = [
        int(vertex)
        for vertex in sorted(vertex_bits, key=lambda item: vertex_bits[item])
    ]
    return {
        "format": "simplicial_nonevasiveness_certificate",
        "schema_version": int(4),
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
            "normalized_complex_cache": bool(NORMALIZED_COMPLEX_CACHE),
            "normalized_cache_max_failures": int(
                NORMALIZED_CACHE_MAX_FAILURES
            ),
            "isomorphism_complex_cache": bool(
                ISOMORPHISM_COMPLEX_CACHE
            ),
            "isomorphism_cache_max_failures": int(
                ISOMORPHISM_CACHE_MAX_FAILURES
            ),
            "automorphism_orbit_pruning": bool(
                AUTOMORPHISM_ORBIT_PRUNING
            ),
            "child_aware_ordering": bool(CHILD_AWARE_ORDERING),
            "child_aware_max_vertices": int(
                CHILD_AWARE_MAX_VERTICES
            ),
            "child_aware_max_facets": int(CHILD_AWARE_MAX_FACETS),
            "obstruction_scheduler": OBSTRUCTION_SCHEDULER,
            "obstruction_adaptive_warmup_calls": int(
                OBSTRUCTION_ADAPTIVE_WARMUP_CALLS
            ),
            "noncollapsibility_obstruction": bool(
                NONCOLLAPSIBILITY_OBSTRUCTION
            ),
            "noncollapsibility_max_vertices": int(
                NONCOLLAPSIBILITY_MAX_VERTICES
            ),
            "noncollapsibility_max_facets": int(
                NONCOLLAPSIBILITY_MAX_FACETS
            ),
            "homology_field_primes": list(HOMOLOGY_FIELD_PRIMES),
            "homology_fields_at_root": bool(HOMOLOGY_FIELDS_AT_ROOT),
            "homology_fields_on_links": bool(HOMOLOGY_FIELDS_ON_LINKS),
            "homology_start_depth": int(HOMOLOGY_START_DEPTH),
            "homology_zz_max_vertices": int(
                HOMOLOGY_ZZ_MAX_VERTICES
            ),
            "homology_zz_max_faces": int(HOMOLOGY_ZZ_MAX_FACES),
            "homology_field_depth_interval": int(
                HOMOLOGY_GF2_DEPTH_INTERVAL
            ),
            "search_state_limit": int(SEARCH_STATE_LIMIT),
            "search_time_limit_seconds": float(
                SEARCH_TIME_LIMIT_SECONDS
            ),
            "search_memory_limit_mib": float(
                SEARCH_MEMORY_LIMIT_MIB
            ),
            "checkpoint_resume_count": int(
                search_stats.checkpoint_resume_count
            ),
            "checkpoint_loaded_states": int(
                search_stats.checkpoint_loaded_states
            ),
            "checkpoint_total_subcomplexes_examined": int(
                search_stats.checkpoint_prior_subcomplexes
                + search_stats.subcomplexes_examined
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
        if "equivalent_state" in record:
            pending.append(record["equivalent_state"])
        elif "isomorphic_state" in record:
            pending.append(record["isomorphic_state"])
        elif "terminal_reason" not in record:
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
        if "equivalent_state" in record:
            pending.append(record["equivalent_state"])
        elif "isomorphic_state" in record:
            pending.append(record["isomorphic_state"])
        elif "terminal_reason" not in record:
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
    stop_reason,
) = is_nonevasive(K, strategy=SEARCH_STRATEGY, rng=rng)
print("\n" + "="*50, flush=True)
if isinstance(stop_reason, SearchInterruptionRequested):
    final_result = RESULT_INCONCLUSIVE_INTERRUPTED
    print(
        "⚠️ The search stopped after an interruption signal. "
        "Completed states were checkpointed; no mathematical conclusion "
        "was drawn.",
        flush=True,
    )
    print(f"Interruption signal: {stop_reason.signal_name}", flush=True)
elif stop_reason is not None:
    final_result = RESULT_INCONCLUSIVE_RESOURCE_LIMIT
    print(
        "⚠️ The search reached a configured resource limit. "
        "No mathematical conclusion was drawn.",
        flush=True,
    )
    print(f"Resource limit reached: {stop_reason.kind}", flush=True)
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
    f"Normalized-complex cache: "
    f"{search_stats.normalized_cache_hits:,} hits; "
    f"{search_stats.normalized_cache_entries:,} current / "
    f"{search_stats.normalized_cache_peak_entries:,} peak "
    f"({search_stats.normalized_cache_success_entries:,} successful, "
    f"{search_stats.normalized_cache_failure_entries:,} failed)",
    flush=True,
)
print(
    f"Normalized-cache failure evictions: "
    f"{search_stats.normalized_cache_evictions:,}",
    flush=True,
)
print(
    f"Certificate equivalence aliases: "
    f"{search_stats.certificate_equivalence_aliases:,}",
    flush=True,
)
print(
    f"Isomorphism cache: "
    f"{search_stats.isomorphism_cache_hits:,} hits; "
    f"{search_stats.isomorphism_cache_entries:,} current / "
    f"{search_stats.isomorphism_cache_peak_entries:,} peak "
    f"({search_stats.isomorphism_cache_success_entries:,} successful, "
    f"{search_stats.isomorphism_cache_failure_entries:,} failed)",
    flush=True,
)
print(
    f"Isomorphism-cache failure evictions: "
    f"{search_stats.isomorphism_cache_evictions:,}",
    flush=True,
)
print(
    f"Certificate isomorphism aliases: "
    f"{search_stats.certificate_isomorphism_aliases:,}",
    flush=True,
)
print(
    f"Automorphism orbit pruning: "
    f"{search_stats.automorphism_orbit_computations:,} computations; "
    f"{search_stats.automorphism_orbits:,} orbits; "
    f"{search_stats.automorphism_vertices_pruned:,} vertex attempts pruned",
    flush=True,
)
print(
    f"Certificate orbit automorphisms: "
    f"{search_stats.certificate_orbit_automorphisms:,}",
    flush=True,
)
print(
    f"Child-aware ordering: "
    f"{search_stats.child_aware_states_scored:,} states scored; "
    f"{search_stats.child_aware_states_skipped:,} skipped by size limits; "
    f"{search_stats.child_aware_states_reordered:,} reordered",
    flush=True,
)
print(
    f"Child preclassifications: "
    f"{search_stats.child_preclassifications:,} total "
    f"({search_stats.child_preclassified_positive:,} positive, "
    f"{search_stats.child_preclassified_negative:,} negative)",
    flush=True,
)
print(
    f"Obstruction scheduler: {OBSTRUCTION_SCHEDULER}; "
    f"{search_stats.obstruction_schedules:,} schedules; "
    f"{search_stats.obstruction_reorders:,} reordered",
    flush=True,
)
for name, profile in search_stats.obstruction_profiles.items():
    seconds_per_rejection = (
        "n/a"
        if not profile["rejections"]
        else f"{profile['seconds'] / profile['rejections']:.6f}s"
    )
    print(
        f"Obstruction {name}: {profile['calls']:,} calls, "
        f"{profile['rejections']:,} rejections, "
        f"{profile['seconds']:.6f} seconds, "
        f"{seconds_per_rejection} per rejection",
        flush=True,
    )
print(
    f"No-free-face obstruction: "
    f"{search_stats.noncollapsibility_states_eligible:,} eligible; "
    f"{search_stats.noncollapsibility_states_skipped:,} size-gated",
    flush=True,
)
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
    f"seconds={SEARCH_TIME_LIMIT_SECONDS:g}; "
    f"memory_mib={SEARCH_MEMORY_LIMIT_MIB:g}",
    flush=True,
)
print(
    f"Checkpointing: "
    f"{'disabled' if CHECKPOINT_PATH is None else str(CHECKPOINT_PATH)}; "
    f"{search_stats.checkpoint_writes:,} writes; "
    f"{search_stats.checkpoint_loaded_states:,} states loaded; "
    f"resume count {search_stats.checkpoint_resume_count:,}",
    flush=True,
)
print(
    f"Cumulative cache misses across checkpoint sessions: "
    f"{search_stats.checkpoint_prior_subcomplexes + search_stats.subcomplexes_examined:,}",
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
for prime, profile in search_stats.homology_field_profiles.items():
    if prime == 2:
        continue
    print(
        f"Homology GF({prime}): {profile['calls']:,} calls, "
        f"{profile['rejections']:,} rejections, "
        f"{profile['seconds']:.3f} seconds",
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
noncollapsibility_rejections = search_stats.obstruction_profiles.get(
    "no_free_face", {}
).get("rejections", 0)
homology_field_calls_summary = ",".join(
    str(prime) + ":" + str(profile["calls"])
    for prime, profile in search_stats.homology_field_profiles.items()
)
homology_field_rejections_summary = ",".join(
    str(prime) + ":" + str(profile["rejections"])
    for prime, profile in search_stats.homology_field_profiles.items()
)
print(
    f"FINAL_RESULT: {final_result}; "
    f"vertex_attempts={search_stats.vertex_attempts}; "
    f"subcomplexes_examined={search_stats.subcomplexes_examined}; "
    f"cache_hits={search_stats.cache_hits}; "
    f"cache_evictions={search_stats.cache_evictions}; "
    f"normalized_cache_enabled={NORMALIZED_COMPLEX_CACHE}; "
    f"normalized_cache_hits={search_stats.normalized_cache_hits}; "
    f"normalized_cache_evictions="
    f"{search_stats.normalized_cache_evictions}; "
    f"certificate_equivalence_aliases="
    f"{search_stats.certificate_equivalence_aliases}; "
    f"isomorphism_cache_enabled={ISOMORPHISM_COMPLEX_CACHE}; "
    f"isomorphism_cache_hits={search_stats.isomorphism_cache_hits}; "
    f"isomorphism_cache_evictions="
    f"{search_stats.isomorphism_cache_evictions}; "
    f"certificate_isomorphism_aliases="
    f"{search_stats.certificate_isomorphism_aliases}; "
    f"automorphism_orbit_pruning={AUTOMORPHISM_ORBIT_PRUNING}; "
    f"automorphism_orbit_computations="
    f"{search_stats.automorphism_orbit_computations}; "
    f"automorphism_vertices_pruned="
    f"{search_stats.automorphism_vertices_pruned}; "
    f"certificate_orbit_automorphisms="
    f"{search_stats.certificate_orbit_automorphisms}; "
    f"search_strategy={SEARCH_STRATEGY}; "
    f"child_aware_ordering={CHILD_AWARE_ORDERING}; "
    f"child_aware_states_scored="
    f"{search_stats.child_aware_states_scored}; "
    f"child_aware_states_skipped="
    f"{search_stats.child_aware_states_skipped}; "
    f"child_aware_states_reordered="
    f"{search_stats.child_aware_states_reordered}; "
    f"child_preclassifications="
    f"{search_stats.child_preclassifications}; "
    f"obstruction_scheduler={OBSTRUCTION_SCHEDULER}; "
    f"obstruction_schedules={search_stats.obstruction_schedules}; "
    f"obstruction_reorders={search_stats.obstruction_reorders}; "
    f"noncollapsibility_obstruction="
    f"{NONCOLLAPSIBILITY_OBSTRUCTION}; "
    f"noncollapsibility_rejections="
    f"{noncollapsibility_rejections}; "
    f"state_engine={STATE_ENGINE}; "
    f"elapsed_seconds={elapsed:.6f}; "
    f"peak_rss_mib={peak_rss_mib:.3f}; "
    f"recursive_calls={search_stats.recursive_calls}; "
    f"deepest_path={search_stats.deepest_path}; "
    f"sage_state_materializations="
    f"{search_stats.sage_state_materializations}; "
    f"search_state_limit={SEARCH_STATE_LIMIT}; "
    f"search_time_limit_seconds={SEARCH_TIME_LIMIT_SECONDS:g}; "
    f"search_memory_limit_mib={SEARCH_MEMORY_LIMIT_MIB:g}; "
    f"checkpoint_enabled={CHECKPOINT_PATH is not None}; "
    f"checkpoint_writes={search_stats.checkpoint_writes}; "
    f"checkpoint_loaded_states="
    f"{search_stats.checkpoint_loaded_states}; "
    f"checkpoint_resume_count="
    f"{search_stats.checkpoint_resume_count}; "
    f"total_subcomplexes_examined="
    f"{search_stats.checkpoint_prior_subcomplexes + search_stats.subcomplexes_examined}; "
    f"resource_limit="
    f"{search_stats.resource_limit_kind or 'none'}; "
    f"link_first_rejections={search_stats.link_first_rejections}; "
    f"protected_vertex_policy={PROTECTED_VERTEX_POLICY}; "
    f"restricted_vertices_skipped="
    f"{search_stats.restricted_vertices_skipped}; "
    f"homology_zz_calls={search_stats.homology_zz_calls}; "
    f"homology_gf2_calls={search_stats.homology_gf2_calls}; "
    f"homology_field_primes="
    f"{','.join(str(prime) for prime in HOMOLOGY_FIELD_PRIMES)}; "
    f"homology_field_calls={homology_field_calls_summary}; "
    f"homology_field_rejections={homology_field_rejections_summary}",
    flush=True,
)
print(pretty_time, flush=True)
search_stats.phase = "completed"
log_heartbeat(
    "completed", result=final_result, elapsed_seconds=float(elapsed)
)
