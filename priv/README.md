# Batata private artifacts

`Batata.TermRuntime` writes host-specific Zig libraries beneath
`priv/term_runtime/` at development time. The directory is kept in the
application so callers can resolve Batata's source and artifact paths without
depending on their current working directory.
