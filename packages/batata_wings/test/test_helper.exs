exclude = if System.get_env("WINGS_ORACLE_PATH"), do: [], else: [oracle: true]
ExUnit.start(exclude: exclude)
