import random
from collections import Counter
from collections import namedtuple
from sage.topology.simplicial_complex import SimplicialComplex
from sage.graphs.graph import Graph

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

# Safe deletion function — builds a new complex without vertex v
def delete_vertex(K, v):
    new_facets = [f for f in K.facets() if v not in f]
    return SimplicialComplex(new_facets)

def is_simplex(K):
    return len(K.facets()) == 1 and set(K.facets()[0]) == set(K.vertices())

def true_link(K, s):
    s = set(s) if isinstance(s, (list, tuple, set)) else {s}
    faces = []
    for face in K.faces():
        # Handle 0-simplices
        face_set = set(face) if hasattr(face, '__iter__') else {face}
        if s.isdisjoint(face_set) and s.union(face_set) in K:
            faces.append(tuple(face_set))
    return SimplicialComplex(faces)  

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
    for facet in K.facets():
        verts = list(facet)
        if len(verts) == 2:
            edges.append(tuple(verts))
        elif len(verts) == 1:
            # Single vertex is isolated — optional, only needed for is_tree() to be accurate
            edges.append((verts[0], verts[0]))
    G = Graph(edges)

    if G.is_tree() or G.is_path():
        return True
    
    return False

# Recursive function to check nonevasiveness
def is_nonevasive(K, ordering=None, depth=0, strategy="greedy"):

    indent = "" # "  " * depth
    # print(f"{indent}↪ Checking complex with {len(K.facets())} facets, dim {K.dimension()}")
    if ordering is None:
        ordering = []

    # Base case: C is a simplex
    if is_simplex(K):
        # print(f"{indent}✓ Base case: Complex is a simplex — Nonevasive")
        return [(ordering.copy(), {})]
        
    # Base case: C is a single point
    if K.dimension() == 0 and len(K.vertices()) == 1:
        # print(f"{indent}✓ Base case: Complex is a single point — Nonevasive")
        return [(ordering.copy(), {})]

    if is_1d_skeletion(K) and is_graph_nonevasive(K):
        return [(ordering.copy(), {})]

    # Vertex selection strategies
    vertices = get_vertices_by_strategy(K, strategy)
    #print(vertices)
    for v in vertices:
        #print(f"{indent}  - Testing with vertex: {v}")
        lk = K.link([v])
        del_K = delete_vertex(K, v)

        link_results = [r for r in is_nonevasive(lk, [], depth + 1, strategy=strategy) if r[0] is not None]
        del_results = [r for r in is_nonevasive(del_K, [], depth + 1, strategy=strategy) if r[0] is not None]
        if not link_results or not del_results:
            continue
        link_orderings, link_histories = zip(*link_results)
        del_orderings, del_histories = zip(*del_results)
        for link_ordering, link_history in zip(link_orderings, link_histories):
            for del_ordering, del_history in zip(del_orderings, del_histories):
                full_order = del_ordering + [v] + link_ordering
                # return [full_order]
                history = {(v, tuple(ordering)): {"link": link_ordering, "del": del_ordering}}
                history.update(link_history)
                history.update(del_history)
                return [(full_order, history)]

    return [(None, {})]
  
# Run the test
result_paths = is_nonevasive(K, strategy="greedy")
print("\n" + "="*50)
if result_paths:
    path, history = result_paths[0]
    print(f"✅ The complex is non-evasive. Found 1 valid deletion path.")
    print("Deletion path:", path)
    print("History (vertex: (link_subpath, deletion_subpath)):")
    for vertex, (link_subpath, del_subpath) in history.items():
        print(f"  Vertex {vertex}: link path = {link_subpath}, deletion path = {del_subpath}")
else:
    print("❌ The complex is evasive. No deletion order found.")