from datetime import datetime, timedelta, UTC
from sage.topology.simplicial_complex import SimplicialComplex
from sage.graphs.graph import Graph
import ast, json, os, time, math
from itertools import combinations

FACETS_FILE = os.environ.get("FACETS_FILE")
DELETE_N = int(os.environ.get("DELETE_N", "5"))

def load_facets_from_file(path):
    with open(path, "r") as f:
        text = f.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return ast.literal_eval(text)
    
if not os.path.exists(FACETS_FILE):
    raise FileNotFoundError(f"FACETS_FILE not found: {FACETS_FILE}")

def delete_vertices(K, vertices_to_delete):
    new_K = SimplicialComplex(K.facets())
    faces_to_remove = [[v] for v in vertices_to_delete]
    new_K.remove_faces(faces_to_remove)
    return SimplicialComplex(new_K.facets())

facets = load_facets_from_file(FACETS_FILE)

# Build the complex
K = SimplicialComplex(facets)
vertices = sorted(K.vertices())
total = math.comb(len(vertices), DELETE_N)

if DELETE_N < 0:
    raise ValueError("DELETE_N must be >= 0")
if DELETE_N > len(vertices):
    raise ValueError("DELETE_N cannot exceed the number of vertices")

print(f"Vertices: {len(vertices)}", flush=True)
print(f"Delete N: {DELETE_N}", flush=True)
print(f"Total combinations: {total}", flush=True)
start_time = time.time()

for idx, combo in enumerate(combinations(vertices, DELETE_N), start=1):
    del_K = delete_vertices(K, combo)
    hom = del_K.homology()
    print(f"{idx}/{total} combo={combo} homology={repr(hom)}", flush=True)

end_time = time.time()
elapsed = end_time - start_time
pretty_time = str(timedelta(seconds=int(elapsed)))
print(pretty_time, flush=True)