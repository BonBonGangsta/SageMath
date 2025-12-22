import random
import time
from datetime import datetime, timedelta, UTC
from collections import Counter
from sage.topology.simplicial_complex import SimplicialComplex
from sage.graphs.graph import Graph
import os
import json
import csv

seed_env = os.environ.get("RANDOM_SEED")
facets = [
    [ 2, 3, 4, 7 ], [ 2, 3, 4, 10 ], 
  [ 2, 3, 7, 10 ], [ 2, 4, 5, 7 ], [ 2, 4, 5, 10 ], [ 2, 5, 7, 13 ], 
  [ 2, 5, 8, 10 ], [ 2, 5, 8, 13 ], [ 2, 6, 9, 11 ], [ 2, 6, 11, 13 ], 
  [ 2, 6, 12, 13 ], [ 2, 7, 8, 10 ], [ 2, 7, 8, 11 ], [ 2, 7, 11, 13 ], 
  [ 2, 8, 9, 11 ], [ 2, 8, 9, 12 ], [ 2, 8, 12, 13 ], [ 3, 4, 6, 7 ], 
  [ 3, 4, 6, 10 ], [ 3, 5, 8, 13 ], [ 3, 5, 9, 11 ], [ 3, 5, 9, 13 ], 
  [ 3, 6, 7, 12 ], [ 3, 6, 10, 13 ], [ 3, 6, 12, 13 ], [ 3, 7, 10, 12 ], 
  [ 3, 8, 9, 11 ], [ 3, 8, 9, 12 ], [ 3, 8, 12, 13 ], [ 3, 9, 10, 12 ], 
  [ 3, 9, 10, 13 ], [ 4, 5, 6, 7 ], [ 4, 5, 6, 10 ], [ 5, 6, 7, 9 ], 
  [ 5, 6, 9, 11 ], [ 5, 6, 10, 11 ], [ 5, 7, 9, 13 ], [ 6, 10, 11, 13 ]
]

# Build the complex
K = SimplicialComplex(facets)

# add csv capabilities
CSV_OUTPUT = os.environ.get("CSV_OUTPUT", "outputs/B12_38_tree.csv")

def export_proof_tree_to_csv(node, csv_path=CSV_OUTPUT):
    """Write the proof tree (link/deletion branches) to a CSV."""
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
            "deletion": self.deletion.to_dict() if self.deletion else None,
        }

# Path for the heartbeat log, very useful for debugging and monitoring large knots
CONTAINER_ID = os.environ.get("CONTAINER_ID", "default")
HEARTBEAT_FILE = f"/heartbeats/sage_heartbeat_{CONTAINER_ID}.log"
last_heartbeat = 0  # Initialize globally

def log_heartbeat(status="running"):
    global last_heartbeat
    now = time.time()
    # Write heartbeat every 5 minutes max
    if now - last_heartbeat >= 300 or status != "running":
        last_heartbeat = now
        payload = {
            "status": status,
            "timestamp": datetime.now(UTC).isoformat(),
            "container_id": CONTAINER_ID
        }
        with open(HEARTBEAT_FILE, "a") as f:
            json.dump(payload, f)
            f.write("\n")
        print(f"[HEARTBEAT] {json.dumps(payload)}" , flush=True)

# Safe deletion function — builds a new complex without vertex v
def delete_vertex(K, v):
    new_K = SimplicialComplex(K.facets())
    new_K.remove_faces([[v]])
    return SimplicialComplex(new_K.facets())

def get_vertices_by_strategy(K, strategy="greedy", rng=None):
    # Vertex selection strategies
    if strategy == "greedy":
        vertices = sorted(K.vertices(), key=lambda x: (len(K.link(x).facets()), x))
    elif strategy == "random":
        vertices = list(K.vertices())
        (rng or random).shuffle(vertices)
    elif strategy == "max_degree":
        vertex_count = Counter(v for f in K.facets() for v in f)
        vertices = sorted(K.vertices(), key=lambda x: -vertex_count[x])
    elif strategy == "min_degree":
        vertex_count = Counter(v for f in K.facets() for v in f)
        vertices = sorted(K.vertices(), key=lambda x: vertex_count[x])
    elif strategy == "exhaustive":
        vertices = list(K.vertices())
    else:
        raise ValueError(f"Unknown strategy: {strategy}")
    return vertices


# Recursive function to check nonevasiveness
def is_nonevasive(K, ordering=None, depth=0, strategy="greedy", context_path=(), mode=None, rng=None):

    if ordering is None:
        ordering = []

    # Base case: A is a simplex
    if Polyhedron(K.facets()).is_simplex():
        node = ProofNode(None, ordering.copy())
        return [(ordering.copy(), node)]

    # Base case: K is a single point
    if K.dimension() == 0:
        if len(K.vertices()) == 1:
            node = ProofNode(None, ordering.copy())
            return [(ordering.copy(), node)]
        else:
            return [(None, None)]

    # Vertex selection strategies
    vertices = get_vertices_by_strategy(K, strategy, rng=rng)
    for v in vertices:
        log_heartbeat("running")

        lk = K.link([v])
        link_result = is_nonevasive(lk, ordering + [v], depth + 1, strategy=strategy, rng=rng)
        if not link_result or link_result[0][0] is None:
            continue

        del_K = delete_vertex(K, v)
        del_result = is_nonevasive(del_K, ordering + [v], depth + 1, strategy=strategy, rng=rng)
        if not del_result or del_result[0][0] is None:
            continue

        # Only use the first result for each (since only one tree needed)
        node = ProofNode(v, ordering.copy())
        node.link = link_result[0][1]
        node.deletion = del_result[0][1]
        return [(ordering + [v], node)]
    return [(None, None)]

# Run the test
start_time = time.time()
if seed_env is not None:
    seed = int(seed_env)
else: 
    seed = random.SystemRandom().randrange(1_000_000_000)

print(f"Using Seed: {seed}", flush=True)
rng = random.Random(seed)
result_paths = is_nonevasive(K, strategy="random", rng=rng)
print("\n" + "="*50, flush=True)
if result_paths:
    path, node = result_paths[0]
    if path is not None:
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

end_time = time.time()
elapsed = end_time - start_time
pretty_time = str(timedelta(seconds=int(elapsed)))
print(pretty_time, flush=True)
log_heartbeat("completed")
