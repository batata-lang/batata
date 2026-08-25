# Batata Wings Godot

`batata_wings_godot` is the narrow renderer boundary between the headless
`batata_wings` geometry kernel and Godot 4.6.2. It does not contain editor UI,
wx, OpenGL, or a second geometry model.

The first vertical slice performs:

```text
Batata.Wings cube → Catmull–Clark once → topology validation
  → fixed-point surface contract → Batata native compilation
  → declared ArrayMesh method bind → Godot headless verification
```

The subdivided cube remains 26 vertices, 48 winged edges, and 24 quad faces
with Euler characteristic 2 inside `batata_wings`. Only the renderer boundary
triangulates it to 48 triangles. Coordinates use an explicit scale of 36 so
the Batata materialization unit contains stable integers; the closed Godot
codec performs the only projection to `Vector3`.

The generated `mesh_receipt.json` binds the Wings upstream commit, canonical
mesh digest, topology invariants, fixed-point descriptor digest, Batata source
digest, Godot binding-plan digest, Godot API version, and artifact bundle.

Inside the monorepo:

```sh
export BATATA_PATH=../..
export BATATA_GODOT_PATH=../batata_godot
export BATATA_WINGS_PATH=../batata_wings
mix deps.get
mix test
```
