exclusions =
  []
  |> then(fn tags -> if :os.type() == {:unix, :darwin}, do: tags, else: [:darwin | tags] end)
  |> then(fn tags ->
    if System.get_env("BATATA_OBJC_APPKIT_SMOKE") == "1", do: tags, else: [:appkit | tags]
  end)

ExUnit.start(exclude: exclusions)
