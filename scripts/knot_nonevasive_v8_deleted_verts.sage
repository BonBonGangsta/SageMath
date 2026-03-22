import random
import time
from datetime import datetime, timedelta, UTC
from sage.topology.simplicial_complex import SimplicialComplex
from sage.graphs.graph import Graph
import csv, ast, json, os

seed_env = os.environ.get("RANDOM_SEED")
facets_file = os.environ.get("FACETS_FILE")
knot_name = os.environ.get("KNOT_NAME")

def load_facets_from_file(path):
    with open(path, "r") as f:
        text = f.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return ast.literal_eval(text)

if facets_file:
    facets = load_facets_from_file(facets_file)


# Build the complex
K = SimplicialComplex(facets)
DEL_VERTS = [41,50,105,159,161,288,333,340,389,426,446,564,589,646,
		1,2,3,4,5,6,7,9,11,14,15,16,23,25,28,32,34,37,38,43,
		44,45,47,48,52,53,55,57,58,59,60,64,67,71,74,75,78,79,
		82,84,87,88,89,92,97,98,100,101,108,109,112,113,118,125,
		126,130,132,133,134,135,137,138,140,142,143,144,149,150,
		154,155,158,160,163,164,165,166,168,172,173,174,176,177,
		180,184,188,189,190,191,196,197,198,199,201, 205,206,207,
		209,210,214,215,220,222,223,224,229,233,235,236,239,244,245,
		247,249,250,251,253,254,256,257,258,260,261,263,264,266,
		267,268,270,271,273,274,275,276,279,280,281,282,286,287,289,
		290,291,292,297,300,306,308,309,315,316,317,319,320,321,
        327,330,331,334,335,338,341,342,343,344,347,348,349,350,351,352,
        357,358,363,364,366,369,370,372,374,376,378,379,381,383,384,385,
        390,393,395,397,399,401,402,403,406,410,413,414,419,423,424,427,
        431,432]

# add csv capabilities
CSV_OUTPUT = os.environ.get("CSV_OUTPUT", f"outputs/{knot_name}_nonevasive_tree.csv")

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
HEARTBEAT_FILE = f"sage_heartbeat_{knot_name}.log"
last_heartbeat = 0  # Initialize globally

def log_heartbeat(status="running"):
    global last_heartbeat
    now = time.time()
    # Write heartbeat every hour
    if now - last_heartbeat >= 86400 or status != "running":
        last_heartbeat = now
        payload = {
            "status": status,
            "timestamp": datetime.now(UTC).isoformat(),
            "container_id": knot_name
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
    # K is a SimplicialComplex at the point of calling
    dim = K.dimension()
    vertices = set(K.vertices())
    facets = [set(f) for f in K.facets()]

    # 0D: a single point
    if dim == 0:
        return len(vertices) == 1
    
    # 1D: a tree (connected and acyclic graph)
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

def has_trivial_homology(K):
    hom = K.homology()
    return all(h.order() == 1 for h in hom.values())

def delete_vertices(K, vertices_to_delete):
    new_K = SimplicialComplex(K.facets())
    faces_to_remove = [[v] for v in vertices_to_delete]
    new_K.remove_faces(faces_to_remove)
    return SimplicialComplex(new_K.facets())

# Recursive function to check nonevasiveness
def is_nonevasive(K, ordering=None, depth=0, strategy="greedy", context_path=(), mode=None, rng=None):

    if ordering is None:
        ordering = []

    # Early Prune: nontrivial homology, cause apparently that's important now
    #if not has_trivial_homology(K):
    #    return [(None, None)]
    
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

    # Vertex selection strategies
    vertices = get_vertices_by_strategy(K, strategy, rng=rng)
    for v in vertices:
        log_heartbeat("running")

        del_K = delete_vertex(K, v)
        if has_trivial_homology(del_K):
            continue
        del_result = is_nonevasive(del_K, [], depth + 1, strategy=strategy, rng=rng)
        if not del_result or del_result[0][0] is None:
                continue

        lk = K.link([v])
        link_result = is_nonevasive(lk, [], depth + 1, strategy=strategy, rng=rng)
        if not link_result or link_result[0][0] is None:
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

print(f"Using Seed: {seed}", flush=true)
rng = random.Random(seed)
K = delete_vertices(K, DEL_VERTS)
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
