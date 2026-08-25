defmodule Batata.ObjC.BindingPlan do
  @moduledoc """
  Closed, target-specific description of one Objective-C binding surface.

  A plan contains only reviewed classes, selectors and callbacks. Unknown ABI,
  ownership, nullability and threading semantics are rejected before native
  code is built.
  """

  alias Batata.ObjC.Diagnostic

  defmodule Class do
    @moduledoc "A declared Objective-C class."
    @enforce_keys [:name, :thread]
    defstruct @enforce_keys
  end

  defmodule Selector do
    @moduledoc "A typed Objective-C selector."
    @enforce_keys [
      :class,
      :name,
      :kind,
      :arguments,
      :returns,
      :ownership,
      :nullable,
      :thread
    ]
    defstruct @enforce_keys
  end

  defmodule Callback do
    @moduledoc "A closed protocol callback implemented by compiled Batata."
    @enforce_keys [:protocol, :selector, :arguments, :returns, :symbol, :thread]
    defstruct @enforce_keys
  end

  @schema 1
  @targets ["aarch64-macos", "x86_64-macos"]
  @frameworks ["Foundation", "AppKit"]
  @threads [:any, :main]
  @ownerships [:none, :borrowed, :retained, :autoreleased, :weak]
  @kinds [:class, :instance]
  @scalar_types [
    :void,
    :bool,
    :i8,
    :u8,
    :i16,
    :u16,
    :i32,
    :u32,
    :i64,
    :u64,
    :isize,
    :usize,
    :f64,
    :cgfloat
  ]
  @opaque_types [:class, :selector]
  @struct_types [:point, :size, :rect]
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @symbol ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @enforce_keys [
    :schema,
    :module,
    :target,
    :minimum_macos,
    :sdk,
    :sdk_digest,
    :frameworks,
    :classes,
    :selectors,
    :callbacks
  ]
  defstruct @enforce_keys

  @type value_type ::
          atom()
          | {:object, String.t()}
          | {:object, String.t(), :nullable}

  @type t :: %__MODULE__{}

  @doc "Builds and validates a closed binding plan from a metadata manifest."
  @spec new!(module(), map(), keyword()) :: t()
  def new!(module, manifest, options \\ []) when is_atom(module) and is_map(manifest) do
    target = Keyword.get(options, :target, host_target())
    minimum_macos = Keyword.get(options, :minimum_macos, "14.0")

    validate_target!(target)
    validate_version!(minimum_macos, :minimum_macos)
    validate_manifest_keys!(manifest)

    frameworks =
      manifest
      |> Map.fetch!("frameworks")
      |> Enum.map(&validate_framework!/1)
      |> Enum.uniq()
      |> Enum.sort()

    classes = manifest |> Map.fetch!("classes") |> Enum.map(&normalize_class!/1) |> sort_classes()

    selectors =
      manifest
      |> Map.fetch!("selectors")
      |> Enum.map(&normalize_selector!/1)
      |> sort_selectors()

    callbacks =
      manifest
      |> Map.fetch!("callbacks")
      |> Enum.map(&normalize_callback!/1)
      |> sort_callbacks()

    validate_references!(classes, selectors, callbacks)

    %__MODULE__{
      schema: @schema,
      module: module,
      target: target,
      minimum_macos: minimum_macos,
      sdk: Map.fetch!(manifest, "sdk"),
      sdk_digest: Map.fetch!(manifest, "sdk_digest"),
      frameworks: frameworks,
      classes: classes,
      selectors: selectors,
      callbacks: callbacks
    }
  end

  @doc "Returns the JSON-ready canonical plan."
  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = plan) do
    %{
      "callbacks" => Enum.map(plan.callbacks, &callback_map/1),
      "classes" => Enum.map(plan.classes, &class_map/1),
      "frameworks" => plan.frameworks,
      "minimum_macos" => plan.minimum_macos,
      "module" => Atom.to_string(plan.module),
      "schema" => plan.schema,
      "sdk" => plan.sdk,
      "sdk_digest" => plan.sdk_digest,
      "selectors" => Enum.map(plan.selectors, &selector_map/1),
      "target" => plan.target
    }
  end

  @doc "Encodes the canonical plan with lexicographically stable map keys."
  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = plan), do: plan |> canonical_map() |> JSON.encode!()

  @doc "Returns the lowercase SHA-256 digest of the canonical plan."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = plan) do
    plan |> canonical_json() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  @doc "Returns the target corresponding to the current BEAM host."
  @spec host_target() :: String.t()
  def host_target do
    case {:erlang.system_info(:system_architecture), :os.type()} do
      {architecture, {:unix, :darwin}} ->
        if String.starts_with?(to_string(architecture), "aarch64"),
          do: "aarch64-macos",
          else: "x86_64-macos"

      _ ->
        diagnostic!("E_OBJC_TARGET_UNSUPPORTED", "Objective-C AppKit requires macOS", %{
          os: inspect(:os.type())
        })
    end
  end

  defp validate_manifest_keys!(manifest) do
    required = ~w(callbacks classes frameworks sdk sdk_digest selectors)
    keys = Map.keys(manifest)
    missing = required -- keys
    unknown = keys -- required

    if missing != [] or unknown != [] do
      diagnostic!("E_OBJC_METADATA_INCOMPLETE", "metadata manifest shape is not closed", %{
        missing: Enum.sort(missing),
        unknown: Enum.sort(unknown)
      })
    end

    validate_version!(Map.fetch!(manifest, "sdk"), :sdk)

    digest = Map.fetch!(manifest, "sdk_digest")

    unless is_binary(digest) and Regex.match?(~r/^sha256:[0-9a-f]{64}$/, digest) do
      diagnostic!("E_OBJC_METADATA_INCOMPLETE", "metadata SDK digest is invalid", %{
        sdk_digest: inspect(digest)
      })
    end
  end

  defp normalize_class!(%{"name" => name, "thread" => thread} = class)
       when map_size(class) == 2 do
    %Class{name: identifier!(name, :class), thread: enum!(thread, @threads, :thread)}
  end

  defp normalize_class!(class),
    do: diagnostic!("E_OBJC_METADATA_INCOMPLETE", "invalid class descriptor", %{class: class})

  defp normalize_selector!(selector) when is_map(selector) do
    allowed = ~w(arguments class kind name nullable ownership returns thread)
    exact_keys!(selector, allowed, :selector)

    %Selector{
      class: selector |> Map.fetch!("class") |> identifier!(:class),
      name: selector |> Map.fetch!("name") |> selector_name!(),
      kind: selector |> Map.fetch!("kind") |> enum!(@kinds, :kind),
      arguments: selector |> Map.fetch!("arguments") |> Enum.map(&type!/1),
      returns: selector |> Map.fetch!("returns") |> type!(),
      ownership: selector |> Map.fetch!("ownership") |> enum!(@ownerships, :ownership),
      nullable: boolean!(Map.fetch!(selector, "nullable"), :nullable),
      thread: selector |> Map.fetch!("thread") |> enum!(@threads, :thread)
    }
  end

  defp normalize_callback!(callback) when is_map(callback) do
    allowed = ~w(arguments protocol returns selector symbol thread)
    exact_keys!(callback, allowed, :callback)

    %Callback{
      protocol: callback |> Map.fetch!("protocol") |> identifier!(:protocol),
      selector: callback |> Map.fetch!("selector") |> selector_name!(),
      arguments: callback |> Map.fetch!("arguments") |> Enum.map(&type!/1),
      returns: callback |> Map.fetch!("returns") |> type!(),
      symbol: callback |> Map.fetch!("symbol") |> symbol!(),
      thread: callback |> Map.fetch!("thread") |> enum!(@threads, :thread)
    }
  end

  defp validate_references!(classes, selectors, callbacks) do
    class_names = MapSet.new(classes, & &1.name)

    Enum.each(selectors, fn selector ->
      unless MapSet.member?(class_names, selector.class) do
        diagnostic!("E_OBJC_METADATA_INCOMPLETE", "selector references an undeclared class", %{
          class: selector.class,
          selector: selector.name
        })
      end
    end)

    duplicates =
      selectors
      |> Enum.frequencies_by(&{&1.class, &1.kind, &1.name})
      |> Enum.filter(fn {_key, count} -> count > 1 end)

    if duplicates != [] do
      diagnostic!("E_OBJC_METADATA_INCOMPLETE", "duplicate selector descriptor", %{
        selectors: Enum.map(duplicates, fn {key, _count} -> inspect(key) end)
      })
    end

    callback_duplicates =
      callbacks
      |> Enum.frequencies_by(&{&1.protocol, &1.selector})
      |> Enum.filter(fn {_key, count} -> count > 1 end)

    if callback_duplicates != [] do
      diagnostic!("E_OBJC_METADATA_INCOMPLETE", "duplicate callback descriptor", %{
        callbacks: Enum.map(callback_duplicates, fn {key, _count} -> inspect(key) end)
      })
    end
  end

  defp type!(type) when is_binary(type) do
    atom = String.to_existing_atom(type)

    if atom in (@scalar_types ++ @opaque_types ++ @struct_types),
      do: atom,
      else: unsupported_type!(type)
  rescue
    ArgumentError -> unsupported_type!(type)
  end

  defp type!(%{"object" => class} = value) when map_size(value) == 1,
    do: {:object, identifier!(class, :object)}

  defp type!(%{"nullable_object" => class} = value) when map_size(value) == 1,
    do: {:object, identifier!(class, :object), :nullable}

  defp type!(type), do: unsupported_type!(type)

  defp unsupported_type!(type) do
    diagnostic!("E_OBJC_TYPE_ENCODING_UNSUPPORTED", "metadata contains an unsupported type", %{
      type: inspect(type)
    })
  end

  defp validate_framework!(framework) when framework in @frameworks, do: framework

  defp validate_framework!(framework) do
    diagnostic!("E_OBJC_METADATA_INCOMPLETE", "framework is outside the closed set", %{
      framework: inspect(framework)
    })
  end

  defp validate_target!(target) when target in @targets, do: :ok

  defp validate_target!(target) do
    diagnostic!("E_OBJC_TARGET_UNSUPPORTED", "target is outside the Objective-C ABI matrix", %{
      target: inspect(target),
      supported: @targets
    })
  end

  defp validate_version!(version, field) do
    unless is_binary(version) and Regex.match?(~r/^\d+\.\d+(?:\.\d+)?$/, version) do
      diagnostic!("E_OBJC_METADATA_INCOMPLETE", "invalid version", %{
        field: field,
        value: inspect(version)
      })
    end
  end

  defp exact_keys!(value, allowed, kind) do
    keys = Map.keys(value)
    missing = allowed -- keys
    unknown = keys -- allowed

    if missing != [] or unknown != [] do
      diagnostic!("E_OBJC_METADATA_INCOMPLETE", "#{kind} descriptor shape is not closed", %{
        missing: Enum.sort(missing),
        unknown: Enum.sort(unknown)
      })
    end
  end

  defp identifier!(value, field) when is_binary(value) do
    if Regex.match?(@identifier, value), do: value, else: invalid_identifier!(value, field)
  end

  defp identifier!(value, field), do: invalid_identifier!(value, field)

  defp invalid_identifier!(value, field) do
    diagnostic!("E_OBJC_METADATA_INCOMPLETE", "invalid Objective-C identifier", %{
      field: field,
      value: inspect(value)
    })
  end

  defp selector_name!(value) when is_binary(value) and value != "" do
    segments = String.split(value, ":", trim: false)

    valid =
      if String.ends_with?(value, ":"), do: Enum.drop(segments, -1), else: segments

    if valid != [] and Enum.all?(valid, &Regex.match?(@identifier, &1)),
      do: value,
      else: invalid_identifier!(value, :selector)
  end

  defp selector_name!(value), do: invalid_identifier!(value, :selector)

  defp symbol!(value) when is_binary(value) do
    if Regex.match?(@symbol, value), do: value, else: invalid_identifier!(value, :symbol)
  end

  defp symbol!(value), do: invalid_identifier!(value, :symbol)

  defp boolean!(value, _field) when is_boolean(value), do: value

  defp boolean!(value, field) do
    diagnostic!("E_OBJC_METADATA_INCOMPLETE", "expected a boolean", %{
      field: field,
      value: inspect(value)
    })
  end

  defp enum!(value, allowed, field) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: atom, else: invalid_enum!(value, allowed, field)
  rescue
    ArgumentError -> invalid_enum!(value, allowed, field)
  end

  defp invalid_enum!(value, allowed, field) do
    diagnostic!("E_OBJC_METADATA_INCOMPLETE", "value is outside the closed enum", %{
      field: field,
      value: inspect(value),
      allowed: allowed
    })
  end

  defp sort_classes(classes), do: Enum.sort_by(classes, & &1.name)
  defp sort_selectors(selectors), do: Enum.sort_by(selectors, &{&1.class, &1.kind, &1.name})
  defp sort_callbacks(callbacks), do: Enum.sort_by(callbacks, &{&1.protocol, &1.selector})

  defp class_map(class), do: %{"name" => class.name, "thread" => Atom.to_string(class.thread)}

  defp selector_map(selector) do
    %{
      "arguments" => Enum.map(selector.arguments, &type_map/1),
      "class" => selector.class,
      "kind" => Atom.to_string(selector.kind),
      "name" => selector.name,
      "nullable" => selector.nullable,
      "ownership" => Atom.to_string(selector.ownership),
      "returns" => type_map(selector.returns),
      "thread" => Atom.to_string(selector.thread)
    }
  end

  defp callback_map(callback) do
    %{
      "arguments" => Enum.map(callback.arguments, &type_map/1),
      "protocol" => callback.protocol,
      "returns" => type_map(callback.returns),
      "selector" => callback.selector,
      "symbol" => callback.symbol,
      "thread" => Atom.to_string(callback.thread)
    }
  end

  defp type_map({:object, class}), do: %{"object" => class}
  defp type_map({:object, class, :nullable}), do: %{"nullable_object" => class}
  defp type_map(type), do: Atom.to_string(type)

  defp diagnostic!(code, message, context) do
    raise Diagnostic,
      code: code,
      message: message,
      context: context,
      actions: [%{command: "review the Objective-C metadata allowlist and overrides"}]
  end
end
