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

The first checked-in seed manifest closes only the `ex.add` scalar vertical
slice. It is a clean-bootstrap and parity oracle, not a production fallback.
Production loading must reject missing or incompatible native artifacts rather
than silently selecting the C++ seed or BEAM reference implementation.
