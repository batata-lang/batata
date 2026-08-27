defmodule Batata.ExecutionEngineGroupTest do
  use ExUnit.Case, async: true

  @execution_functions [:execute, :execute_with_memory_report]

  test "async execution-engine cases share the serialized group" do
    violations =
      __DIR__
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.flat_map(&execution_group_violation/1)

    assert violations == [], """
    Batata.execute tests must either be synchronous or use the :execution_engine group:
    #{Enum.join(violations, "\n")}
    """
  end

  defp execution_group_violation(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    case {calls_execution_engine?(ast), case_options(ast)} do
      {false, _options} -> []
      {true, options} when is_list(options) -> option_violation(path, options)
      {true, _options} -> [Path.relative_to(path, File.cwd!())]
    end
  end

  defp option_violation(path, options) do
    if Keyword.get(options, :async, false) and
         Keyword.get(options, :group) != :execution_engine do
      [Path.relative_to(path, File.cwd!())]
    else
      []
    end
  end

  defp calls_execution_engine?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Batata]}, function]}, _, _arguments} = node, _found?
        when function in @execution_functions ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp case_options(ast) do
    {_ast, options} =
      Macro.prewalk(ast, nil, fn
        {:use, _, [{:__aliases__, _, [:Batata, :Case]}, options]} = node, nil ->
          {node, options}

        {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}, options]} = node, nil ->
          {node, options}

        node, options ->
          {node, options}
      end)

    options
  end
end
