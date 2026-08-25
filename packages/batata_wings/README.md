# Batata Wings

`batata_wings` is a provenance-tracked, headless geometry kernel derived from
[Wings3D](https://github.com/dgud/wings). It ports the winged-edge topology and
selected modelling operations into an Elixir surface that Batata can compile.

The package does not port the upstream wx UI or OpenGL renderer. Godot or any
other host consumes a canonical mesh contract without entering the topology
kernel.

The initial source pin is
`dgud/wings@e12ef3ce267c4d9ecb33d4845bdc9275f1a4b433`. See `LICENSE.wings` for
the upstream redistribution terms. Ported files retain source mapping through
`Batata.Wings.Provenance`.

Inside the Batata monorepo:

```sh
export BATATA_PATH=../..
mix deps.get
mix test
```

Mesh JSON is canonical: textual map keys and integer entity IDs are sorted,
and SHA-256 digests are computed from the resulting UTF-8 bytes. Invalid
identity surfaces raise `Batata.Wings.Diagnostic` with stable `E_WINGS_*`
codes instead of producing a partial mesh.

Set `WINGS_ORACLE_PATH` to a clean checkout at the pinned upstream commit to
run the differential Catmull-Clark test. The adapter compiles only the required
upstream Erlang modules together with headless translation/progress stubs; it
does not start wx or OpenGL.
