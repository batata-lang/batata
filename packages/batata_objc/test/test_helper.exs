ExUnit.start(
  exclude: if(System.get_env("BATATA_OBJC_APPKIT_SMOKE") == "1", do: [], else: [:appkit])
)
