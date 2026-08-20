defmodule Batata.Frontend.Literal do
  @moduledoc """
  Pure structural evaluation for bounded frontend constants.

  This module only constructs literal data. It never evaluates quoted code,
  expands host macros, loads modules, or reads application configuration.
  """

  @type result :: {:ok, term()} | :error

  @doc "Evaluates syntax made exclusively from supported literal constructors."
  @spec eval(Macro.t()) :: result()
  def eval(value) when is_atom(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  def eval({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  def eval({:.., _, [first, last]}) do
    with {:ok, first} when is_integer(first) <- eval(first),
         {:ok, last} when is_integer(last) <- eval(last) do
      {:ok, first..last}
    else
      _ -> :error
    end
  end

  def eval({:{}, _, items}) when is_list(items) do
    with {:ok, values} <- eval_list(items), do: {:ok, List.to_tuple(values)}
  end

  def eval({left, right}) do
    with {:ok, left} <- eval(left),
         {:ok, right} <- eval(right) do
      {:ok, {left, right}}
    else
      _ -> :error
    end
  end

  def eval({:%{}, _, pairs}) when is_list(pairs) do
    with {:ok, values} <- eval_list(pairs), do: {:ok, Map.new(values)}
  end

  def eval(values) when is_list(values), do: eval_list(values)
  def eval(_other), do: :error

  @doc "Evaluates an explicitly allowlisted, configuration-independent constant."
  @spec eval_constant(Macro.t()) :: result()
  def eval_constant(
        {{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _, [app, key, default]}
      ) do
    with {:ok, app} when is_atom(app) <- eval(app),
         {:ok, key} when is_atom(key) <- eval(key),
         {:ok, default} <- eval(default) do
      {:ok, default}
    else
      _ -> :error
    end
  end

  def eval_constant(ast), do: eval(ast)

  defp eval_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case eval(value) do
        {:ok, evaluated} -> {:cont, {:ok, [evaluated | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, evaluated} -> {:ok, Enum.reverse(evaluated)}
      :error -> :error
    end
  end
end
