# Batata Probe

`batata_probe` contains the corpus-neutral compatibility engine used to
inventory Elixir source, classify fail-closed compiler frontiers, and emit
deterministic JSON evidence. Corpus policy does not belong here: source pins,
baselines, semantic gates, and user-facing tasks live in packages such as
`batata_jason` and `batata_decimal`.

Coverage dashboards can be merged without re-reading or recompiling their
source corpora:

```console
mix batata.coverage.merge --input jason.json --input decimal.json --output report.json
```
