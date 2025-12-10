import regina

def gluing_perm(tet_a, face_a, tet_b, face_b):
    perm = [-1] * 4

    # First, record which vertex of B is opposite the face we’re gluing.
    perm[face_b] = face_a

    # Now match the three vertices that lie on the face.
    face_vertices = {v for i, v in enumerate(tet_b) if i != face_b}
    for idx_b, v in enumerate(tet_b):
        if idx_b == face_b:
            continue
        idx_a = tet_a.index(v)
        perm[idx_b] = idx_a

    return regina.Perm4(perm)

def perm_to_face_cycle(perm, face_idx):
    mapping = []
    for v in range(4):
        if v == face_idx:
            continue
        mapping.append(str(perm[v]))
    return "(" + "".join(mapping) + ")"

def triangulation_from_sage(S):
    """
    Convert a Sage SimplicialComplex of tetrahedra into a Regina Triangulation3 object (I hope). 
    Assumes tetrahedra share faces by indentivcal vertex sets.
    """

    tets = sorted(
    [tuple(sorted(list(simplex))) for simplex in S.facets() if simplex.dimension() == 3]
    )


    T = regina.Triangulation3()
    reg_tets = []

    for tet in tets:
        reg_tets.append((tet, T.newTetrahedron()))
    
    tet_to_regina = dict(reg_tets)

    face_map = {}

    for i, (tet, r_tet) in enumerate(reg_tets):
        v = tet
        for j in range(4):
            face = tuple(sorted([v[k] for k in range(4) if k != j]))
            face_map.setdefault(face, []).append((i,j))
        
    for face, elems in face_map.items():
        if len(elems) == 2:
            (i1, f1), (i2, f2) = elems
            perm = gluing_perm(reg_tets[i1][0], f1, reg_tets[i2][0], f2)
            reg_tets[i1][1].join(f1, reg_tets[i2][1], perm)

    return T, reg_tets, face_map

def write_regina_table(reg_tets, face_map, path):
    with open(path, "w") as fh:
        fh.write(f"{len(reg_tets)}\n")
        for tet, _ in reg_tets:
            fh.write(" ".join(map(str, tet)) + "\n")

        for idx, (tet, _) in enumerate(reg_tets):
            for face_idx in range(4):
                face = tuple(sorted(tet[k] for k in range(4) if k != face_idx))
                # find the mate glued to this face (if any)
                mates = [entry for entry in face_map[face] if entry != (idx, face_idx)]
                if mates:
                    other_idx, other_face = mates[0]
                    perm = gluing_perm(reg_tets[idx][0], face_idx,
                                       reg_tets[other_idx][0], other_face)
                    perm_str = " ".join(str(perm[i]) for i in range(4))
                    fh.write(f"{idx} {face_idx} {other_idx} {other_face} {perm_str}\n")
                else:
                    # boundary face
                    fh.write(f"{idx} {face_idx} -1 -1 0 1 2 3\n")

def write_regina_tablev2(reg_tets, face_map, path):
    with open(path, "w") as fh:
        fh.write(f"{len(reg_tets)}\n")
        for idx, _ in enumerate(reg_tets):
            fh.write(f"{idx} (0123)\n")  # or another permutation of 0..3, if needed
        fh.write("\n")
        for idx, (tet, _) in enumerate(reg_tets):
            for face_idx in range(4):
                face = tuple(sorted(tet[k] for k in range(4) if k != face_idx))
                mates = [entry for entry in face_map[face] if entry != (idx, face_idx)]
                if mates:
                    other_idx, other_face = mates[0]
                    perm = gluing_perm(reg_tets[idx][0], face_idx,
                                       reg_tets[other_idx][0], other_face)
                    perm_face = "(" + "".join(str(perm[v]) for v in range(4) if v != face_idx) + ")"
                    fh.write(f"{idx} {face_idx} {other_idx} {other_face} {perm_face}\n")
                else:
                    fh.write(f"{idx} {face_idx} -1 -1 ()\n")

S = SimplicialComplex([[1,2,4,6], [1,3,4,6], [1,3,5,6], [2,3,4,6]])
T, reg_tets, face_map = triangulation_from_sage(S)
write_regina_tablev2(reg_tets, face_map, "output.tri")

print("Saved as output.tri")