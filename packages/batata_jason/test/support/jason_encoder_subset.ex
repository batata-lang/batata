defmodule Batata.Jason.Test.EncoderSubset do
  @moduledoc false

  # Derived from Jason 1.4.5's encode/2 output boundary, which turns the
  # nested iodata returned by Jason.Encode into the public binary result.
  def source(iodata) do
    """
    defmodule JasonEncoderSubset do
      def main(), do: IO.iodata_to_binary(#{inspect(iodata)})
    end
    """
  end
end
