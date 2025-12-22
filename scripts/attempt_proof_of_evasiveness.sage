import csv
import os
from sage.topology.simplicial_complex import SimplicialComplex
from itertools import count
step_counter = count(1)

facets = [
[1, 3, 7, 13], [2, 4, 10,14], [3, 6, 10, 11], [4, 5, 8, 13], [5, 7, 11, 14], [6, 10, 13, 14], 
[1, 3, 9, 13], [2, 6, 8, 12], [3, 6, 10, 14], [4, 7, 11, 12], [5, 8, 12, 13], [7, 11, 12, 13], 
[1, 5, 7, 11], [2, 6, 10, 12], [3, 7, 12, 13], [4, 8, 11, 12], [5, 9, 12, 13], [8, 12, 13, 14], 
[1, 5, 9, 11], [2, 8, 12, 14], [3, 7, 11, 14], [4, 8, 13, 14], [5, 9, 11, 14], [9, 11, 13, 14], 
[1, 7, 11, 13], [2, 10, 12, 14], [3, 9, 12, 13], [4, 10, 13, 14], [6, 8, 11,12], [10, 11, 12, 14], 
[1, 9, 11, 13], [3, 4, 7, 11], [3, 10, 11, 14], [5, 6, 9, 13], [6, 9, 13, 14], 
[11, 12, 13, 14], [2, 4, 8, 14], [3, 4, 7, 12], [4, 5, 8, 12], [5, 6, 9, 14], [6, 10, 11, 12]
]

class Node:
    def __init__(self, vertex, depth, branch):
        self.vertex = None if vertex == "" else int(vertex)
        self.depth = depth
        self.branch = branch  # root|link|deletion
        self.children = []    # expect at most link + deletion

def save_graph(G, label, step, out_dir="outputs/plots"):
    os.makedirs(out_dir, exist_ok=True)
    fname = f"{step:02d}_{label}.png"   # e.g., 01_link_v3.png
    path = os.path.join(out_dir, fname)
    G.plot(save_pos=True).save(path)
    print(f"saved {path}")

def build_tree(csv_path):
    rows = list(csv.DictReader(open(csv_path)))
    stack = []
    root = None
    for r in rows:
        node = Node(r["vertex"], int(r["depth"]), r["branch"])
        while stack and stack[-1].depth >= node.depth:
            stack.pop()
        if stack:
            stack[-1].children.append(node)
        else:
            root = node
        stack.append(node)
    return root

def delete_vertex(K, v):
    if v not in K.vertices():
        raise ValueError(f"vertex {v} not in current complex")
    new_K = SimplicialComplex(K.facets())
    new_K.remove_faces([[v]])
    return SimplicialComplex(new_K.facets())

def replay(node, K):
    if node.vertex is None:
        print("Base case")
        return
    v = node.vertex
    # link branch
    lk = K.link([v])
    print(f"Link of {v}, facets={lk.facets()}, homology={lk.homology()}")
    save_graph(lk.graph(), f"link_v{v}", next(step_counter))
    for child in node.children:
        if child.branch == "link":
            replay(child, lk)
    # deletion branch
    delK = delete_vertex(K, v)
    print(f"Deletion of {v}, facets={delK.facets()}, homology={delK.homology()}")
    save_graph(delK.graph(), f"del_v{v}", next(step_counter))
    for child in node.children:
        if child.branch == "deletion":
            replay(child, delK)
    return 


K = SimplicialComplex(facets)
print(f"Initial facets: {K.facets()}")
tree = build_tree("outputs/rudins_tree.csv")
replay(tree, K)
