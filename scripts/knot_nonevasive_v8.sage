import random
import time
import csv, ast, json, os
from datetime import datetime, timedelta, UTC
from sage.topology.simplcial_complex import SimplicialComplex
from sage.graphs.graph import Graph
from pathlib import Path
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
HEARTBEAT_FILE = f"sage_heartbeat_{knot_name}.log"
last_heartbeat = 0
v_counter = 0

def log_heartbeat(status="running"):
    global last_heartbeat
    global v_counter
    now = time.time()
    # Write hearbeat every day
    if now - last_heartbeat >= 86400 or status != "running":
        last_heartbeat = now
        payload = {
            "status": status,
            "timestamp": datetime.now(UTC).isoformat(),
            "container_id": knot_name,
            "vertices_visited": v_counter
        }
        with open(HEARTBEAT_FILE, "a") as f:
            json.dump(payload, f)
            f.write("\n")

# Safe Deletion function build into SageMath
def delete_vertex(K, v):
    new_K = SimplicialComplex(K.facets())
    new_K.remove_faces([[v]])
    return SimplicialComplex(new_K.facets())

def is_simplex(K):
    # K is a SimplicialComplex at the point of calling
    dim = K.dimension()
    vertices = set(K.vertices())
    facets = [set(f) for f in K.facets()]

    # 0D: a single point?
    if dim == 0:
        return len(vertices) == 1
    
    # 1D: a tree ( connected and acyclic graph)?
    if dim == 1:
        if any(len(f) > 2 for f in facets):
            return False
        edges = [tuple(f) for f in facets if len(f) == 2]
        if not edges:
            return False
        G = Graph()
        G.add_vertices(vertices)
        G.add_edges(edges)
        return G.is_tree()

    # 2D: a filled triangle on exactly three vertices
    if dim == 2:
        if len(vertices) != 3:
            return False
        maximal = [set(f) for f in K.facets()]
        return len(maximal) == 1 and maximal[0] == vertices
    
    # 3D: a filled tetrahedron on exactly four vertices
    if dim == 3:
        if len(vertices) != 4:
            return False
        maximal = [set(f) for f in K.facets()]
        return len(maximal) == 1 and maximal[0] == vertices
    
    return False

def get_vertices_by_strategy(K, strategy="greedy", rng=None):
    if strategy == "greedy":
        vertices = sorted(K.vertices(), key=lambda x: (len(K.link(x).facets()), x))
    elif strategy == "random":
        vertices = list(K.vertices())
        (rng or random).shuffle(vertices)
    elif strategy == "max_degree":
        vertex_count = Counter(v for f in K.facets() for v in f)
        vertices = sorted(K.vertices(), key=lambda x: -vertex_count[x])
    elif strategy == "exhaustive":
        vertices = list(K.vertices())
    else:
        raise ValueError(f"Unknown strategy: {strategy}")
    return vertices

def has_trivial_homology(K):
    hom = K.homology()
    return all(h.order() == 1 for h in hom.values())

def is_nonevasive(K, ordering=None, depth=0, strategy="random", context_path=(), mode=None, rng=None):
    global v_counter
    if ordering is None:
        ordering = []
    
    if K.dimension() == 0:
        if len(K.vertices()) == 1:
            node = ProofNode(None, ordering.copy())
            return [(ordering.copy(), node)]
        else:
            return [(None, None)]
        
    vertices = get_vertices_by_strategy(K, strategy, rng=rng)
    for v in vertices:
        v_counter += 1
        log_heartbeat("running")

        del_k = delete_vertex(K, v)
        if not has_trivial_homology(del_k):
            continue
        print(f"Found Potential Vertex: {v}", flush=True)
        
        del_result = is_nonevasive(del_k, [], depth + 1, strategy=strategy, rng=rng)
        if not del_result or del_result[0][0] is None:
            continue

        lk = K.link([v])
        link_result = is_nonevasive(lk, [], depth + 1, strategy=strategy, rng=rng)
        if not link_result or link_result[0][0] is None:
            continue

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
