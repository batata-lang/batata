# The Zig term runtime shared library is used by the JIT-based end-to-end
# term tests; build it once before the suite starts.
Batata.TermRuntime.ensure_built!()

ExUnit.start()
