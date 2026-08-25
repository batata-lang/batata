defmodule Batata.ObjC.AppKit.ApplicationPlan do
  @moduledoc "Closed declaration of one minimal AppKit application."

  alias Batata.ObjC.Diagnostic

  @enforce_keys [:module, :name, :bundle_identifier, :window, :label, :button, :callbacks]
  defstruct @enforce_keys

  @type frame :: {number(), number(), number(), number()}
  @type t :: %__MODULE__{}

  @identifier ~r/^[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z0-9-]+)+$/
  @name ~r/^[A-Za-z][A-Za-z0-9_-]*$/
  @callback_names [:did_finish_launching, :button_pressed, :should_terminate]

  @doc false
  @spec new!(module(), keyword(), list(), list(), list(), [atom()]) :: t()
  def new!(module, options, windows, labels, buttons, definitions) do
    validate_options!(options)
    name = options |> Keyword.fetch!(:name) |> identifier!(:name, @name)

    bundle_identifier =
      options
      |> Keyword.fetch!(:bundle_identifier)
      |> identifier!(:bundle_identifier, @identifier)

    callbacks =
      Map.new(@callback_names, fn callback ->
        unless {callback, 0} in definitions do
          diagnostic!(
            "E_OBJC_CALLBACK_SIGNATURE_MISMATCH",
            "required AppKit callback is not defined",
            %{
              callback: callback,
              arity: 0
            }
          )
        end

        {callback, Batata.Symbol.function(callback, 0)}
      end)

    %__MODULE__{
      module: module,
      name: name,
      bundle_identifier: bundle_identifier,
      window: one!(windows, :window, &normalize_window!/1),
      label: one!(labels, :label, &normalize_label!/1),
      button: one!(buttons, :button, &normalize_button!/1),
      callbacks: callbacks
    }
  rescue
    error in KeyError ->
      diagnostic!("E_OBJC_APPLICATION_PLAN_INVALID", "missing AppKit application option", %{
        option: error.key
      })
  end

  @doc "Returns a deterministic JSON-ready application descriptor."
  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = plan) do
    %{
      "bundle_identifier" => plan.bundle_identifier,
      "button" => control_map(plan.button),
      "callbacks" =>
        plan.callbacks
        |> Enum.sort()
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end),
      "label" => control_map(plan.label),
      "module" => Atom.to_string(plan.module),
      "name" => plan.name,
      "schema" => 1,
      "window" => %{"frame" => Tuple.to_list(plan.window.frame), "title" => plan.window.title}
    }
  end

  @doc "Returns canonical JSON for the application descriptor."
  @spec canonical_json(t()) :: String.t()
  def canonical_json(plan), do: plan |> canonical_map() |> JSON.encode!()

  @doc "Returns the application descriptor SHA-256 digest."
  @spec digest(t()) :: String.t()
  def digest(plan) do
    plan |> canonical_json() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp validate_options!(options) do
    required = [:bundle_identifier, :name]
    keys = Keyword.keys(options)
    missing = required -- keys
    unknown = keys -- required

    if missing != [] or unknown != [] do
      diagnostic!(
        "E_OBJC_APPLICATION_PLAN_INVALID",
        "AppKit application options are not closed",
        %{
          missing: missing,
          unknown: unknown
        }
      )
    end
  end

  defp one!([declaration], _kind, normalize), do: normalize.(declaration)

  defp one!(declarations, kind, _normalize) do
    diagnostic!("E_OBJC_APPLICATION_PLAN_INVALID", "AppKit MVP requires exactly one #{kind}", %{
      count: length(declarations)
    })
  end

  defp normalize_window!(options) do
    exact_options!(options, [:frame, :title], :window)

    %{
      title: text!(Keyword.fetch!(options, :title), :window_title),
      frame: frame!(Keyword.fetch!(options, :frame))
    }
  end

  defp normalize_label!(options) do
    exact_options!(options, [:frame, :text], :label)

    %{
      text: text!(Keyword.fetch!(options, :text), :label_text),
      frame: frame!(Keyword.fetch!(options, :frame))
    }
  end

  defp normalize_button!(options) do
    exact_options!(options, [:action, :frame, :title], :button)
    action = Keyword.fetch!(options, :action)

    unless action == :button_pressed do
      diagnostic!(
        "E_OBJC_SELECTOR_UNDECLARED",
        "button action is outside the closed callback set",
        %{
          action: inspect(action),
          supported: [:button_pressed]
        }
      )
    end

    %{
      title: text!(Keyword.fetch!(options, :title), :button_title),
      frame: frame!(Keyword.fetch!(options, :frame)),
      action: action
    }
  end

  defp exact_options!(options, allowed, kind) do
    keys = Keyword.keys(options)
    missing = allowed -- keys
    unknown = keys -- allowed

    if missing != [] or unknown != [] do
      diagnostic!("E_OBJC_APPLICATION_PLAN_INVALID", "#{kind} declaration is not closed", %{
        missing: missing,
        unknown: unknown
      })
    end
  end

  defp frame!({x, y, width, height})
       when is_number(x) and is_number(y) and is_number(width) and is_number(height) and width > 0 and
              height > 0,
       do: {x / 1, y / 1, width / 1, height / 1}

  defp frame!(frame) do
    diagnostic!(
      "E_OBJC_APPLICATION_PLAN_INVALID",
      "frame must contain positive width and height",
      %{
        frame: inspect(frame)
      }
    )
  end

  defp identifier!(value, _field, regex) when is_binary(value) do
    if Regex.match?(regex, value), do: value, else: invalid_identifier!(value)
  end

  defp identifier!(value, _field, _regex), do: invalid_identifier!(value)

  defp invalid_identifier!(value) do
    diagnostic!("E_OBJC_APPLICATION_PLAN_INVALID", "invalid AppKit application identifier", %{
      value: inspect(value)
    })
  end

  defp text!(value, _field) when is_binary(value) and byte_size(value) in 1..255, do: value

  defp text!(value, field) do
    diagnostic!("E_OBJC_APPLICATION_PLAN_INVALID", "AppKit text must contain 1 to 255 bytes", %{
      field: field,
      value: inspect(value)
    })
  end

  defp control_map(control) do
    %{
      "action" => control[:action] && Atom.to_string(control.action),
      "frame" => Tuple.to_list(control.frame),
      "title" => control[:title],
      "text" => control[:text]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp diagnostic!(code, message, context) do
    raise Diagnostic,
      code: code,
      message: message,
      context: context,
      actions: [%{command: "review the Batata.ObjC.AppKit.Application declaration"}]
  end
end
