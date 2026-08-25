defmodule Batata.Wings.Godot.EditorInput do
  @moduledoc "A closed, canonical input protocol for the Godot editor boundary."

  alias Batata.Godot.Diagnostic
  alias Batata.Wings.{CanonicalJSON, Geometry}

  @pointer_keys ~w(button camera_ray expected_generation kind modifiers position pressed)
  @key_keys ~w(expected_generation key kind modifiers pressed)
  @buttons ~w(primary secondary middle)
  @keys ~w(z y)
  @modifiers ~w(alt command control shift)

  @type t :: map()

  @doc "Validates and canonicalizes one declared editor event."
  @spec normalize!(map()) :: t()
  def normalize!(%{"kind" => "pointer_button"} = event) do
    exact_keys!(event, @pointer_keys)
    vector2!(event["position"], "position")
    ray!(event["camera_ray"])
    enum!(event["button"], @buttons, "button")
    boolean!(event["pressed"], "pressed")
    generation!(event["expected_generation"])
    modifiers = modifiers!(event["modifiers"])
    Map.put(event, "modifiers", modifiers)
  end

  def normalize!(%{"kind" => "key_chord"} = event) do
    exact_keys!(event, @key_keys)
    enum!(event["key"], @keys, "key")
    boolean!(event["pressed"], "pressed")
    generation!(event["expected_generation"])
    modifiers = modifiers!(event["modifiers"])
    Map.put(event, "modifiers", modifiers)
  end

  def normalize!(event) do
    unsupported!("editor event subtype is not declared", %{"event" => inspect(event)})
  end

  @doc "Returns the canonical digest carried by replay receipts."
  @spec digest(t()) :: binary()
  def digest(event) do
    event
    |> normalize!()
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns the versioned closed event schema advertised by the extension."
  @spec schema() :: map()
  def schema do
    %{
      "events" => %{
        "key_chord" => %{"fields" => @key_keys, "keys" => @keys},
        "pointer_button" => %{"buttons" => @buttons, "fields" => @pointer_keys}
      },
      "modifiers" => @modifiers,
      "schema_version" => 1
    }
  end

  @doc "Returns the canonical schema digest pinned in editor receipts."
  @spec schema_digest() :: binary()
  def schema_digest do
    schema()
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp exact_keys!(event, expected) do
    observed = event |> Map.keys() |> Enum.sort()

    if observed != expected do
      unsupported!("editor event fields do not match the closed schema", %{
        "expected_fields" => expected,
        "observed_fields" => observed
      })
    end
  end

  defp ray!(%{"direction" => direction, "origin" => origin} = ray) do
    if map_size(ray) != 2 do
      unsupported!("camera ray contains undeclared fields", %{"ray" => inspect(ray)})
    end

    vector3!(origin, "camera_ray.origin")
    vector3!(direction, "camera_ray.direction")
  end

  defp ray!(ray), do: unsupported!("camera ray is malformed", %{"ray" => inspect(ray)})

  defp vector2!([x, y], _field) when is_number(x) and is_number(y), do: :ok

  defp vector2!(value, field),
    do: unsupported!("editor vector is malformed", %{"field" => field, "value" => inspect(value)})

  defp vector3!([x, y, z], _field) do
    unless Geometry.finite_vector?({x, y, z}) do
      unsupported!("editor vector must be finite", %{"value" => inspect([x, y, z])})
    end
  end

  defp vector3!(value, field),
    do: unsupported!("editor vector is malformed", %{"field" => field, "value" => inspect(value)})

  defp enum!(value, allowed, field) do
    unless value in allowed do
      unsupported!("editor enum value is unsupported", %{
        "allowed" => allowed,
        "field" => field,
        "value" => inspect(value)
      })
    end
  end

  defp boolean!(value, _field) when is_boolean(value), do: :ok

  defp boolean!(value, field),
    do:
      unsupported!("editor boolean is malformed", %{"field" => field, "value" => inspect(value)})

  defp generation!(value) when is_integer(value) and value >= 0, do: :ok

  defp generation!(value),
    do: unsupported!("editor generation is malformed", %{"value" => inspect(value)})

  defp modifiers!(modifiers) when is_list(modifiers) do
    canonical = modifiers |> Enum.uniq() |> Enum.sort()

    if length(canonical) != length(modifiers) or Enum.any?(canonical, &(&1 not in @modifiers)) do
      unsupported!("editor modifiers are not a canonical declared set", %{
        "allowed" => @modifiers,
        "value" => inspect(modifiers)
      })
    end

    canonical
  end

  defp modifiers!(value),
    do: unsupported!("editor modifiers are malformed", %{"value" => inspect(value)})

  defp unsupported!(message, context) do
    raise Diagnostic,
      code: "E_GODOT_EDITOR_EVENT_UNSUPPORTED",
      message: message,
      context: Map.put(context, "recovery", "encode one declared editor event"),
      actions: [%{command: "discard the event and preserve the displayed mesh"}]
  end
end
