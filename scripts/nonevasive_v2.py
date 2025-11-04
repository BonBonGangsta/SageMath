from itertools import combinations

MAX_DEPTH = 11
max_depth_reached = -1

def delete_vertex(complex_, v):
    return [face for face in complex_ if v not in face]

def link(complex_, v):
    link_faces = set()
    for face in complex_:
        if v in face:
            subface = tuple(sorted(set(face) - {v}))
            for i in range(len(subface) + 1):
                for subset in combinations(subface, i):
                    link_faces.add(subset)
    return list(link_faces)

def is_non_evasive_trace(complex_, depth=0, seen=None):
    global max_depth_reached, MAX_DEPTH

    if seen is None:
        seen = set()
    
    if depth > MAX_DEPTH:
        return False, []

    if depth > max_depth_reached:
        max_depth_reached = depth
        print(f"New max depth reached: {depth}")

    frozen = frozenset(frozenset(face) for face in complex_)
    if frozen in seen:
        return False, []
    seen.add(frozen)

    if not complex_:
        return True, []

    vertices = sorted(set(v for face in complex_ for v in face))
    for v in vertices:
        del_c = delete_vertex(complex_, v)
        link_c = link(complex_, v)
        del_result, del_trace = is_non_evasive_trace(del_c, depth + 1, seen.copy())
        link_result, link_trace = is_non_evasive_trace(link_c, depth + 1, seen.copy())
        if del_result and link_result:
            return True, [v] + del_trace

    return False, []


complex_ = [tuple(sorted(f)) for f in [
    [0, 1, 2, 6],
    [0, 1, 3, 4],
    [0, 1, 3, 6],
    [0, 2, 3, 5],
    [0, 2, 5, 6],
    [0, 3, 5, 6],
    [1, 2, 4, 5],
    [1, 2, 4, 6],
    [1, 3, 4, 6],
    [2, 4, 5, 6]
    ]
]
result = is_non_evasive_trace(complex_)
print("Complex_ is non-evasive?", result[0])
print("Deletion sequence:", result[1])
