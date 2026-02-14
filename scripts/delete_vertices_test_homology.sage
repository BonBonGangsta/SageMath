from datetime import datetime, timedelta, UTC
from sage.topology.simplicial_complex import SimplicialComplex
from sage.graphs.graph import Graph
import ast, json, os, time, math
from itertools import combinations

FACETS_FILE = os.environ.get("FACETS_FILE")
DELETE_N = int(os.environ.get("DELETE_N", "5"))
TRIVIAL_DEL = [41,0]
#TRIVIAL_DEL = [41,50,105,159,161,288,333,340,389,426,446,564,589,646,
#		1,2,3,4,5,6,7,9,11,14,15,16,23,25,28,32,34,37,38,43,
#		44,45,47,48,52,53,55,57,58,59,60,64,67,71,74,75,78,79,
#		82,84,87,88,89,92,97,98,100,101,108,109,112,113,118,125,
#		126,130,132,133,134,135,137,138,140,142,143,144,149,150,
#		154,155,158,160,163,164,165,166,168,172,173,174,176,177,
#		180,184,188,189,190,191,196,197,198,199,201, 205,206,207,
#		209,210,214,215,220,222,223,224,229,233,235,236,239,244,245,
#		247,249,250,251,253,254,256,257,258,260,261,263,264,266,
#		267,268,270,271,273,274,275,276,279,280,281,282,286,287,289,
#		290,291,292,297,300,306,308,309]
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

def is_trivial_hg(hg):
    # your objects have order() and trivial ones return 1
    return getattr(hg, "order", lambda: None)() == 1

def homology_is_trivial(C):
    H = C.homology()
    return all(is_trivial_hg(hg) for hg in H.values())

facets = load_facets_from_file(FACETS_FILE)

# Build the complex
K = SimplicialComplex(facets)
#K = delete_vertices(K, TRIVIAL_DEL)
vertices = TRIVIAL_DEL
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
    print(f"we've deleted {combo} from K", flush=True)
    hom = del_K.homology()
    if all(h.order() == 1 for h in hom.values()):
        print("✅ TRIVIAL:", combo, hom, flush=True)
end_time = time.time()
elapsed = end_time - start_time
pretty_time = str(timedelta(seconds=int(elapsed)))
print(pretty_time, flush=True)