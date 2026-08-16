defmodule Batata.NativeDeps.Command do
  @moduledoc false

  def run!(command, args, opts \\ []) do
    print? = Keyword.get(opts, :print_output, false)
    opts = opts |> Keyword.delete(:print_output) |> Keyword.delete(:into)

    case System.cmd(command, args, Keyword.merge([stderr_to_stdout: true], opts)) do
      {output, 0} ->
        if print?, do: IO.binwrite(output)
        output

      {output, status} when is_binary(output) ->
        Mix.raise("#{command} failed with status #{status}:\n#{output}")

      {_stream, status} ->
        Mix.raise("#{command} failed with status #{status}")
    end
  end
end
