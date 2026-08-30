# Batata Compiler Kernel

This package owns Batata's evolving Ex conversion source, native shared
library, manifest instances, and bootstrap receipts. Beaver owns only the
provider-neutral compiler-kernel ABI, loader/trampoline, and frozen Stage 0
seed.

The dependency direction is always:

```text
Beaver generic ABI
        ↓
Batata compiler kernel
```

The checked-in seed manifest closes the first pure-scalar source subset. It is
a clean-bootstrap and parity oracle, not a production fallback.
Production loading must reject missing or incompatible native artifacts rather
than silently selecting the C++ seed or BEAM reference implementation.

## Production provider

Batata defaults to the callback-free native provider. Configure the Stage 2
manifest, its shared library, and the exact ABI identity expected by the host:

```elixir
config :batata,
  compiler_kernel: [
    manifest: "/opt/batata/compiler-kernel.json",
    artifact: "/opt/batata/libbatata_ex_conversion.so",
    expected: [
      beaver_revision: "<40-hex commit>",
      dialect_schema_digest: "sha256:<64-hex digest>",
      runtime_abi_digest: "sha256:<64-hex digest>",
      target: %{
        "triple" => "<target triple>",
        "cpu" => "<cpu>",
        "features" => []
      }
    ]
  ]
```

Loading fails before IR mutation when the configuration is missing, the
artifact digest or identity drifts, or the manifest is not a
`previous-native` Stage 2 build. Bootstrap tools and reference tests must opt
in explicitly with `conversion_provider: :cpp_bootstrap`; production never
falls back to it.
