import random
import time
from datetime import datetime, timedelta, UTC
from collections import Counter
from collections import namedtuple
from sage.topology.simplicial_complex import SimplicialComplex
from sage.graphs.graph import Graph
import os
import json

# Define the 3-ball via facets
facets = [
    [0, 1, 2, 3],
    [0, 1, 2, 4],
    [0, 1, 4, 5],
    [0, 1, 5, 7],
    [0, 1, 6, 8],
    [0, 1, 7, 8],
    [0, 2, 3, 4],
    [0, 6, 7, 8],
    [1, 2, 3, 6],
    [1, 2, 4, 5],
    [1, 2, 5, 8],
    [1, 2, 6, 8],
    [1, 5, 7, 8],
    [2, 3, 4, 7],
    [2, 3, 6, 7],
    [2, 4, 6, 7],
    [2, 4, 6, 8],
    [4, 6, 7, 8]
]

# Build the complex
K = SimplicialComplex(facets)

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

def is_simplex(K):
    return len(K.facets()) == 1 and set(K.facets()[0]) == set(K.vertices())

def get_vertices_by_strategy(K, strategy="greedy"):
    # Vertex selection strategies
    if strategy == "greedy":
        vertices = sorted(K.vertices(), key=lambda x: (len(K.link(x).facets()), x))
    elif strategy == "random":
        vertices = list(K.vertices())
        random.shuffle(vertices)
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

def is_1d_skeletion(K):
    return K.dimension() <= 1 and all(len(list(facet)) <= 2 for facet in K.facets())

def is_graph_nonevasive(K):
    edges = []
    vertices = set()

    for facet in K.facets():
        verts = list(facet)
        if len(verts) == 2:
            edges.append(tuple(verts))
        elif len(verts) == 1:
            vertices.add(verts[0])

    G = Graph()
    G.add_edges(edges)
    G.add_vertices(vertices)  # ensure singleton vertices are added

    if G.is_tree() or G.is_path():
        return True

    return False


# Recursive function to check nonevasiveness
def is_nonevasive(K, ordering=None, depth=0, strategy="greedy", context_path=(), mode=None):

    if ordering is None:
        ordering = []

     # Base case: A is a simplex
    if is_simplex(K):
        node = ProofNode(None, ordering.copy())
        return [(ordering.copy(), node)]

    # Base case: K is a single point
    if K.dimension() == 0:
        if len(K.vertices()) == 1:
            node = ProofNode(None, ordering.copy())
            return [(ordering.copy(), node)]
        else:
            return [(None, None)]

    if is_1d_skeletion(K) and is_graph_nonevasive(K):
        node = ProofNode(None, ordering.copy())
        return [(ordering.copy(), node)]


    # Vertex selection strategies
    vertices = get_vertices_by_strategy(K, strategy)
    for v in vertices:
        log_heartbeat("running")

        lk = K.link([v])
        link_result = is_nonevasive(lk, [], depth + 1, strategy=strategy)
        if not link_result or link_result[0][0] is None:
            continue

        del_K = delete_vertex(K, v)
        del_result = is_nonevasive(del_K, [], depth + 1, strategy=strategy)
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
result_paths = is_nonevasive(K, strategy="random")
print("\n" + "="*50, flush=True)
if result_paths:
    path, node = result_paths[0]
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
        if node.deletion:
            print(f"{prefix}  ↪ Deletion:", flush=True)
            print_tree(node.deletion, prefix + "    ")
    if result_paths and result_paths[0][1]:
        print_tree(result_paths[0][1])
else:
    print("❌ The complex is evasive. No deletion order found.", flush=True)

end_time = time.time()
elapsed = end_time - start_time
pretty_time = str(timedelta(seconds=int(elapsed)))
print(pretty_time, flush=True)
log_heartbeat("completed")
