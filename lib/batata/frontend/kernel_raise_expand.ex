defmodule Batata.Frontend.KernelRaiseExpand do
  @moduledoc """
  Normalizes the one-argument Kernel raise boundary without macro expansion.

  Source parsing retains auto-imported `raise/1` as an unqualified call. Keep
  a genuine local definition untouched, but mark imported and explicitly
  qualified Kernel calls so lift cannot mistake them for module-local symbols.
  """

  @exception_kind 9

  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}) do
    forms = body_forms(body)
    local_raise? = Enum.any?(forms, &local_raise_definition?/1)
    forms = Enum.map(forms, &rewrite_form(&1, local_raise?))

    {:defmodule, metadata, [name_ast, [do: block(forms)]]}
  end

  def expand(ast), do: ast

  defp rewrite_form({kind, metadata, [head, [do: body]]}, local_raise?)
       when kind in [:def, :defp] do
    {kind, metadata, [head, [do: rewrite_calls(body, local_raise?)]]}
  end

  defp rewrite_form(form, _local_raise?), do: form

  defp rewrite_calls(ast, local_raise?) do
    Macro.prewalk(ast, fn
      {:raise, _metadata, [reason]} when not local_raise? ->
        {:__batata_raise__, [], [@exception_kind, reason]}

      {{:., _, [module_ast, :raise]}, _, [reason]} = call ->
        if kernel_module?(module_ast),
          do: {:__batata_raise__, [], [@exception_kind, reason]},
          else: call

      node ->
        node
    end)
  end

  defp local_raise_definition?({kind, _, [head, [do: _body]]})
       when kind in [:def, :defp],
       do: signature(head) == {:raise, 1}

  defp local_raise_definition?(_form), do: false

  defp signature({:when, _, [head | _guards]}), do: signature(head)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp signature(_head), do: nil

  defp kernel_module?(Kernel), do: true
  defp kernel_module?({:__aliases__, _, [:Kernel]}), do: true
  defp kernel_module?(_module), do: false

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block([form]), do: form
  defp block(forms), do: {:__block__, [], forms}
end
