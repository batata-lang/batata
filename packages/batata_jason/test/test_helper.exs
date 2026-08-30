Application.put_env(:batata, :conversion_provider, :cpp_bootstrap)
Batata.TermRuntime.ensure_built!()
ExUnit.start()
