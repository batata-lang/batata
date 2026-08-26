# Batata Wings Godot

`batata_wings_godot` is the narrow renderer boundary between the headless
`batata_wings` geometry kernel and Godot 4.6.2. It does not contain editor UI,
wx, OpenGL, or a second geometry model.

The read-only vertical slice performs:

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

The editor slice compiles the checked-in
`Batata.Wings.Native.Kernel` source into the GDExtension library and keeps its
portable state rooted by the Godot instance. The plugin normalizes pointer
events into bounded fixed-point rays and keyboard chords into native undo/redo
transactions. Stale generations, unsupported inputs, quota violations, and
out-of-range coordinates preserve the previous state and displayed mesh. The
native integration replay is:

```text
ray select → move → undo → redo → reject stale move
```

`build_editor_replay!/3` writes `editor_replay_receipt.json`, compiles code
rather than a final editor snapshot, and invokes the native methods plus the
real `ArrayMesh` outbound call under pinned Godot 4.6.2 `--headless --editor`.
Selection indices remain a separate overlay projection; the native state is
the source of truth.

Every `state: :replace` method returns `{new_state, result}` at the native
boundary. The binding deep-exports `new_state` into the instance-owned
portable registry, swaps it only after export succeeds, and releases the prior
root. Repeated same-instance smoke calls verify replacement, history, stale
rejection, mesh refresh, and teardown instead of relying on the execution
arena lifetime.

Inside the monorepo:

```sh
export BATATA_PATH=../..
export BATATA_GODOT_PATH=../batata_godot
export BATATA_WINGS_PATH=../batata_wings
mix deps.get
mix test
```
