defmodule Batata.ObjC.MetadataTest do
  use ExUnit.Case, async: true

  alias Batata.ObjC.{Diagnostic, Metadata}

  test "rejects metadata source drift", %{test: test} do
    path = Path.join(System.tmp_dir!(), "#{test}-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      JSON.encode!(%{
        "sdk" => "26.4",
        "sdk_digest" => "sha256:" <> String.duplicate("0", 64),
        "source" => %{}
      })
    )

    error = assert_raise Diagnostic, fn -> Metadata.load!(path) end
    assert error.code == "E_OBJC_SDK_DRIFT"
    assert error.context.expected != error.context.actual
  end
end
