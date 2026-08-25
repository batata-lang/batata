defmodule Batata.Memory.Bound do
  @moduledoc """
  Canonical symbolic byte bounds used by proof-carrying memory plans.

  Bounds deliberately form a small, total language. They can be normalized,
  serialized, and evaluated without executing compiler code or trusting an AI
  supplied expression.
  """

  @enforce_keys [:op]
  defstruct [:op, :value, :name, terms: []]

  @type t :: %__MODULE__{
          op: :constant | :variable | :sum | :product | :maximum,
          value: non_neg_integer() | nil,
          name: String.t() | nil,
          terms: [t()]
        }

  @spec constant(non_neg_integer()) :: t()
  def constant(value) when is_integer(value) and value >= 0,
    do: %__MODULE__{op: :constant, value: value}

  def constant(value),
    do:
      raise(
        ArgumentError,
        "memory bound constant must be a non-negative integer: #{inspect(value)}"
      )

  @spec variable(String.t()) :: t()
  def variable(name) when is_binary(name) and name != "",
    do: %__MODULE__{op: :variable, name: name}

  def variable(name),
    do: raise(ArgumentError, "memory bound variable must be a non-empty string: #{inspect(name)}")

  @spec add([t()]) :: t()
  def add(terms) when is_list(terms) do
    terms
    |> Enum.flat_map(fn
      %__MODULE__{op: :sum, terms: nested} -> nested
      %__MODULE__{} = term -> [term]
      other -> raise ArgumentError, "memory bound sum received: #{inspect(other)}"
    end)
    |> combine_constants()
    |> canonical_terms()
    |> case do
      [] -> constant(0)
      [term] -> term
      normalized -> %__MODULE__{op: :sum, terms: normalized}
    end
  end

  @spec maximum([t()]) :: t()
  def maximum(terms) when is_list(terms) do
    terms
    |> Enum.flat_map(fn
      %__MODULE__{op: :maximum, terms: nested} -> nested
      %__MODULE__{} = term -> [term]
      other -> raise ArgumentError, "memory bound maximum received: #{inspect(other)}"
    end)
    |> Enum.uniq_by(&canonical_map/1)
    |> canonical_terms()
    |> case do
      [] -> constant(0)
      [term] -> term
      normalized -> %__MODULE__{op: :maximum, terms: normalized}
    end
  end

  @spec multiply([t()]) :: t()
  def multiply(terms) when is_list(terms) do
    terms =
      Enum.flat_map(terms, fn
        %__MODULE__{op: :product, terms: nested} -> nested
        %__MODULE__{} = term -> [term]
        other -> raise ArgumentError, "memory bound product received: #{inspect(other)}"
      end)

    if Enum.any?(terms, &match?(%__MODULE__{op: :constant, value: 0}, &1)) do
      constant(0)
    else
      {constants, symbolic} = Enum.split_with(terms, &(&1.op == :constant))
      factor = Enum.reduce(constants, 1, &(&1.value * &2))
      normalized = if factor == 1, do: symbolic, else: [constant(factor) | symbolic]

      case canonical_terms(normalized) do
        [] -> constant(1)
        [term] -> term
        product -> %__MODULE__{op: :product, terms: product}
      end
    end
  end

  @spec scale(t(), non_neg_integer()) :: t()
  def scale(%__MODULE__{} = term, factor) when is_integer(factor) and factor >= 0 do
    cond do
      factor == 0 -> constant(0)
      factor == 1 -> term
      term.op == :constant -> constant(term.value * factor)
      true -> multiply([constant(factor), term])
    end
  end

  def scale(_term, factor),
    do:
      raise(
        ArgumentError,
        "memory bound scale must be a non-negative integer: #{inspect(factor)}"
      )

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{op: :constant, value: value}),
    do: %{"bytes" => Integer.to_string(value), "op" => "constant"}

  def canonical_map(%__MODULE__{op: :variable, name: name}),
    do: %{"name" => name, "op" => "variable"}

  def canonical_map(%__MODULE__{op: op, terms: terms}) when op in [:sum, :product, :maximum] do
    %{
      "op" => Atom.to_string(op),
      "terms" => Enum.map(terms, &canonical_map/1)
    }
  end

  @spec variables(t()) :: [String.t()]
  def variables(%__MODULE__{op: :constant}), do: []
  def variables(%__MODULE__{op: :variable, name: name}), do: [name]

  def variables(%__MODULE__{terms: terms}) do
    terms |> Enum.flat_map(&variables/1) |> Enum.uniq() |> Enum.sort()
  end

  @spec evaluate(t(), %{optional(String.t()) => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, [String.t()]}
  def evaluate(%__MODULE__{} = bound, contracts \\ %{}) when is_map(contracts) do
    missing = bound |> variables() |> Enum.reject(&valid_contract?(contracts, &1))

    if missing == [] do
      {:ok, evaluate_closed(bound, contracts)}
    else
      {:error, missing}
    end
  end

  defp evaluate_closed(%__MODULE__{op: :constant, value: value}, _contracts), do: value
  defp evaluate_closed(%__MODULE__{op: :variable, name: name}, contracts), do: contracts[name]

  defp evaluate_closed(%__MODULE__{op: :sum, terms: terms}, contracts),
    do: Enum.reduce(terms, 0, &(&2 + evaluate_closed(&1, contracts)))

  defp evaluate_closed(%__MODULE__{op: :product, terms: terms}, contracts),
    do: Enum.reduce(terms, 1, &(&2 * evaluate_closed(&1, contracts)))

  defp evaluate_closed(%__MODULE__{op: :maximum, terms: terms}, contracts),
    do: terms |> Enum.map(&evaluate_closed(&1, contracts)) |> Enum.max(fn -> 0 end)

  defp valid_contract?(contracts, name) do
    case contracts[name] do
      value when is_integer(value) and value >= 0 -> true
      _ -> false
    end
  end

  defp combine_constants(terms) do
    {constants, symbolic} = Enum.split_with(terms, &(&1.op == :constant))
    total = Enum.reduce(constants, 0, &(&1.value + &2))
    if total == 0, do: symbolic, else: [constant(total) | symbolic]
  end

  defp canonical_terms(terms), do: Enum.sort_by(terms, &canonical_map/1)
end
