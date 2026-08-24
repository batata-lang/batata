defmodule Batata.Godot.BindingPlan do
  @moduledoc """
  Validated, canonical description of one generated GDExtension surface.

  The plan is intentionally closed: only types with an implemented ownership
  policy may cross the boundary. The first slice accepts scalar values only.
  """

  alias Batata.Godot.Diagnostic

  defmodule Class do
    @moduledoc "A registered Godot class and its base class."
    @enforce_keys [:name, :base]
    defstruct [:name, :base]

    @type t :: %__MODULE__{name: String.t(), base: String.t()}
  end

  defmodule Method do
    @moduledoc "A Batata function exposed as a typed Godot method."
    @enforce_keys [:name, :arguments, :returns, :symbol]
    defstruct [:name, :arguments, :returns, :symbol]

    @type value_type ::
            nil
            | :bool
            | :int
            | :float
            | :string
            | :string_name
            | :vector2
            | :vector3
            | {:object, String.t()}
    @type t :: %__MODULE__{
            name: String.t(),
            arguments: [value_type()],
            returns: value_type(),
            symbol: String.t()
          }
  end

  defmodule Property do
    @moduledoc "A ClassDB property backed by declared getter and setter methods."
    @enforce_keys [:name, :type, :getter, :setter]
    defstruct @enforce_keys
  end

  defmodule Signal do
    @moduledoc "A typed ClassDB signal declaration."
    @enforce_keys [:name, :arguments]
    defstruct @enforce_keys
  end

  defmodule Virtual do
    @moduledoc "A closed Godot virtual callback implemented by compiled Batata code."
    @enforce_keys [:name, :arguments, :returns, :symbol]
    defstruct @enforce_keys
  end

  @schema 2
  @supported_types [nil, :bool, :int, :float, :string, :string_name, :vector2, :vector3]
  @max_method_arity 8
  @initialization_levels [:core, :servers, :scene, :editor]
  @extension_keys [
    :compatibility_minimum,
    :entry_symbol,
    :extension,
    :initialization_level,
    :reloadable
  ]
  @class_keys [:base]
  @method_keys [:args, :returns]
  @property_keys [:type, :getter, :setter]
  @signal_keys [:args]
  @virtuals %{_ready: {[], nil}, _process: {[:float], nil}}
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @compatibility_version ~r/^\d+\.\d+(?:\.\d+)?$/

  @enforce_keys [
    :schema,
    :module,
    :extension,
    :entry_symbol,
    :compatibility_minimum,
    :reloadable,
    :initialization_level,
    :class,
    :methods,
    :properties,
    :signals,
    :virtuals
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: pos_integer(),
          module: module(),
          extension: String.t(),
          entry_symbol: String.t(),
          compatibility_minimum: String.t(),
          reloadable: boolean(),
          initialization_level: atom(),
          class: Class.t(),
          methods: [Method.t()],
          properties: [Property.t()],
          signals: [Signal.t()],
          virtuals: [Virtual.t()]
        }

  @doc false
  @spec new!(module(), keyword(), list(), list(), list(), list(), list(), list()) :: t()
  def new!(
        module,
        extension_options,
        class_declarations,
        method_declarations,
        property_declarations,
        signal_declarations,
        virtual_declarations,
        definitions
      ) do
    extension_options = validate_options!(extension_options, @extension_keys, :extension)
    class = normalize_class!(class_declarations)

    extension =
      extension_options
      |> Keyword.get(:extension, default_extension(module))
      |> validate_identifier!(:extension)

    entry_symbol =
      extension_options
      |> Keyword.get(:entry_symbol, "#{extension}_library_init")
      |> validate_identifier!(:entry_symbol)

    compatibility_minimum =
      extension_options
      |> Keyword.get(:compatibility_minimum, "4.6")
      |> validate_compatibility!()

    reloadable =
      extension_options |> Keyword.get(:reloadable, false) |> validate_boolean!(:reloadable)

    initialization_level =
      extension_options
      |> Keyword.get(:initialization_level, :scene)
      |> validate_initialization_level!()

    methods = normalize_methods!(method_declarations, definitions)
    properties = normalize_properties!(property_declarations, methods)
    signals = normalize_signals!(signal_declarations)
    virtuals = normalize_virtuals!(virtual_declarations, definitions)

    %__MODULE__{
      schema: @schema,
      module: module,
      extension: extension,
      entry_symbol: entry_symbol,
      compatibility_minimum: compatibility_minimum,
      reloadable: reloadable,
      initialization_level: initialization_level,
      class: class,
      methods: methods,
      properties: properties,
      signals: signals,
      virtuals: virtuals
    }
  end

  @doc "Returns a JSON-ready representation with stable string keys."
  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = plan) do
    %{
      "class" => %{"base" => plan.class.base, "name" => plan.class.name},
      "compatibility_minimum" => plan.compatibility_minimum,
      "entry_symbol" => plan.entry_symbol,
      "extension" => plan.extension,
      "initialization_level" => Atom.to_string(plan.initialization_level),
      "methods" => Enum.map(plan.methods, &method_map/1),
      "properties" => Enum.map(plan.properties, &property_map/1),
      "signals" => Enum.map(plan.signals, &signal_map/1),
      "virtuals" => Enum.map(plan.virtuals, &virtual_map/1),
      "module" => inspect(plan.module),
      "reloadable" => plan.reloadable,
      "schema" => plan.schema
    }
  end

  @doc "Encodes the plan with fixed field ordering for replayable digests."
  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = plan) do
    methods = plan.methods |> Enum.map(&method_json/1) |> Enum.intersperse(",")
    properties = plan.properties |> Enum.map(&property_json/1) |> Enum.intersperse(",")
    signals = plan.signals |> Enum.map(&signal_json/1) |> Enum.intersperse(",")
    virtuals = plan.virtuals |> Enum.map(&virtual_json/1) |> Enum.intersperse(",")

    [
      "{\"schema\":",
      Integer.to_string(plan.schema),
      ",\"module\":",
      json_string(inspect(plan.module)),
      ",\"extension\":",
      json_string(plan.extension),
      ",\"entry_symbol\":",
      json_string(plan.entry_symbol),
      ",\"compatibility_minimum\":",
      json_string(plan.compatibility_minimum),
      ",\"reloadable\":",
      if(plan.reloadable, do: "true", else: "false"),
      ",\"initialization_level\":",
      json_string(Atom.to_string(plan.initialization_level)),
      ",\"class\":{\"name\":",
      json_string(plan.class.name),
      ",\"base\":",
      json_string(plan.class.base),
      "},\"methods\":[",
      methods,
      "],\"properties\":[",
      properties,
      "],\"signals\":[",
      signals,
      "],\"virtuals\":[",
      virtuals,
      "]}"
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Returns the lowercase SHA-256 of `canonical_json/1`."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = plan) do
    plan
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_class!([{name, options}]) do
    options = validate_options!(options, @class_keys, :class)
    name = validate_identifier!(name, :class)
    base = options |> Keyword.get(:base, "RefCounted") |> validate_identifier!(:base_class)
    %Class{name: name, base: base}
  end

  defp normalize_class!([]) do
    diagnostic!(
      "E_GODOT_CLASS_MISSING",
      "an extension must declare exactly one Godot class",
      %{},
      [%{command: "add godot_class \"ClassName\", base: \"RefCounted\""}]
    )
  end

  defp normalize_class!(declarations) do
    diagnostic!(
      "E_GODOT_CLASS_DUPLICATE",
      "an extension may declare only one Godot class in the first binding-plan schema",
      %{count: length(declarations)}
    )
  end

  defp normalize_methods!(declarations, definitions) do
    methods =
      declarations
      |> Enum.map(&normalize_method!(&1, definitions))
      |> Enum.sort_by(&{&1.name, length(&1.arguments)})

    duplicates =
      methods
      |> Enum.frequencies_by(&{&1.name, length(&1.arguments)})
      |> Enum.filter(fn {_signature, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      diagnostic!(
        "E_GODOT_METHOD_DUPLICATE",
        "Godot method names and arities must be unique",
        %{signatures: Enum.map(duplicates, fn {name, arity} -> "#{name}/#{arity}" end)}
      )
    end

    methods
  end

  defp normalize_method!({name, options}, definitions) do
    options = validate_options!(options, @method_keys, :method)
    name = validate_function_name!(name)
    arguments = options |> Keyword.fetch!(:args) |> validate_types!(:arguments)
    returns = options |> Keyword.fetch!(:returns) |> validate_type!(:return)
    signature = {name, length(arguments)}

    if length(arguments) > @max_method_arity do
      diagnostic!(
        "E_GODOT_METHOD_SIGNATURE_UNSUPPORTED",
        "Godot methods support at most #{@max_method_arity} arguments",
        %{method: name, arity: length(arguments), maximum: @max_method_arity}
      )
    end

    unless signature in definitions do
      diagnostic!(
        "E_GODOT_METHOD_FUNCTION_MISSING",
        "declared Godot method has no matching public Batata function",
        %{function: "#{name}/#{length(arguments)}"},
        [%{command: "define def #{name}(...) with the declared arity"}]
      )
    end

    %Method{
      name: Atom.to_string(name),
      arguments: arguments,
      returns: returns,
      symbol: Batata.Symbol.function(name, length(arguments))
    }
  rescue
    error in KeyError ->
      diagnostic!(
        "E_GODOT_METHOD_SIGNATURE_UNSUPPORTED",
        "Godot method declarations require args: and returns:",
        %{method: inspect(name), missing: error.key}
      )
  end

  defp normalize_properties!(declarations, methods) do
    properties =
      declarations
      |> Enum.map(&normalize_property!(&1, methods))
      |> Enum.sort_by(& &1.name)

    reject_duplicate_names!(properties, "E_GODOT_PROPERTY_DUPLICATE", :properties)
  end

  defp normalize_property!({name, options}, methods) do
    options = validate_options!(options, @property_keys, :property)
    property_name = name |> validate_function_name!() |> Atom.to_string()
    type = options |> Keyword.fetch!(:type) |> validate_type!(:property)
    getter = options |> Keyword.fetch!(:getter) |> validate_function_name!() |> Atom.to_string()
    setter = options |> Keyword.fetch!(:setter) |> validate_function_name!() |> Atom.to_string()

    unless Enum.any?(methods, &(&1.name == getter and &1.arguments == [] and &1.returns == type)) do
      diagnostic!(
        "E_GODOT_PROPERTY_ACCESSOR_INVALID",
        "property getter must be a declared zero-arity method returning the property type",
        %{property: property_name, getter: getter}
      )
    end

    unless Enum.any?(
             methods,
             &(&1.name == setter and &1.arguments == [type] and &1.returns == nil)
           ) do
      diagnostic!(
        "E_GODOT_PROPERTY_ACCESSOR_INVALID",
        "property setter must be a declared one-arity method accepting the property type and returning nil",
        %{property: property_name, setter: setter}
      )
    end

    %Property{name: property_name, type: type, getter: getter, setter: setter}
  rescue
    error in KeyError ->
      diagnostic!(
        "E_GODOT_PROPERTY_INVALID",
        "property declarations require type:, getter: and setter:",
        %{property: inspect(name), missing: error.key}
      )
  end

  defp normalize_signals!(declarations) do
    signals =
      declarations
      |> Enum.map(fn {name, options} ->
        options = validate_options!(options, @signal_keys, :signal)
        name = name |> validate_function_name!() |> Atom.to_string()
        arguments = options |> Keyword.get(:args, []) |> validate_types!(:signal)

        if length(arguments) > @max_method_arity do
          diagnostic!(
            "E_GODOT_SIGNAL_SIGNATURE_UNSUPPORTED",
            "Godot signals support at most #{@max_method_arity} arguments",
            %{signal: name, arity: length(arguments), maximum: @max_method_arity}
          )
        end

        %Signal{name: name, arguments: arguments}
      end)
      |> Enum.sort_by(& &1.name)

    reject_duplicate_names!(signals, "E_GODOT_SIGNAL_DUPLICATE", :signals)
  end

  defp normalize_virtuals!(declarations, definitions) do
    virtuals =
      declarations
      |> Enum.map(fn name ->
        name = validate_function_name!(name)

        {arguments, returns} =
          Map.get(@virtuals, name) ||
            diagnostic!(
              "E_GODOT_VIRTUAL_UNSUPPORTED",
              "only the closed _ready and _process callback set is supported",
              %{virtual: name, supported: Map.keys(@virtuals)}
            )

        unless {name, length(arguments)} in definitions do
          diagnostic!(
            "E_GODOT_VIRTUAL_FUNCTION_MISSING",
            "declared Godot virtual has no matching public Batata function",
            %{function: "#{name}/#{length(arguments)}"}
          )
        end

        %Virtual{
          name: Atom.to_string(name),
          arguments: arguments,
          returns: returns,
          symbol: Batata.Symbol.function(name, length(arguments))
        }
      end)
      |> Enum.sort_by(& &1.name)

    reject_duplicate_names!(virtuals, "E_GODOT_VIRTUAL_DUPLICATE", :virtuals)
  end

  defp reject_duplicate_names!(values, code, field) do
    duplicates =
      values
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      diagnostic!(code, "Godot declarations must have unique names", %{field => duplicates})
    end

    values
  end

  defp validate_options!(options, allowed, scope) when is_list(options) do
    if Keyword.keyword?(options) do
      case Keyword.keys(options) -- allowed do
        [] ->
          options

        unknown ->
          diagnostic!(
            "E_GODOT_OPTION_UNKNOWN",
            "binding declaration contains unknown options",
            %{scope: scope, options: unknown}
          )
      end
    else
      diagnostic!(
        "E_GODOT_OPTION_INVALID",
        "binding options must be a keyword list",
        %{scope: scope}
      )
    end
  end

  defp validate_options!(_options, _allowed, scope) do
    diagnostic!(
      "E_GODOT_OPTION_INVALID",
      "binding options must be a keyword list",
      %{scope: scope}
    )
  end

  defp validate_identifier!(value, field) when is_binary(value) do
    if Regex.match?(@identifier, value) do
      value
    else
      diagnostic!(
        "E_GODOT_IDENTIFIER_INVALID",
        "Godot identifiers must start with a letter or underscore and contain only ASCII letters, digits, or underscores",
        %{field: field, value: value}
      )
    end
  end

  defp validate_identifier!(value, field) do
    diagnostic!(
      "E_GODOT_IDENTIFIER_INVALID",
      "Godot identifiers must be strings",
      %{field: field, value: inspect(value)}
    )
  end

  defp validate_function_name!(name) when is_atom(name), do: name

  defp validate_function_name!(name) do
    diagnostic!(
      "E_GODOT_METHOD_SIGNATURE_UNSUPPORTED",
      "a Godot method name must be an atom",
      %{method: inspect(name)}
    )
  end

  defp validate_types!(types, position) when is_list(types) do
    Enum.map(types, &validate_type!(&1, position))
  end

  defp validate_types!(types, position) do
    diagnostic!(
      "E_GODOT_METHOD_SIGNATURE_UNSUPPORTED",
      "Godot method arguments must be a list of supported types",
      %{position: position, value: inspect(types)}
    )
  end

  defp validate_type!(type, _position) when type in @supported_types, do: type

  defp validate_type!({:object, class_name}, _position) do
    {:object, validate_identifier!(class_name, :object_class)}
  end

  defp validate_type!(type, position) do
    diagnostic!(
      "E_GODOT_VARIANT_UNSUPPORTED",
      "the Godot Variant type has no Batata ownership codec",
      %{position: position, type: inspect(type), supported: @supported_types},
      [%{command: "replace the value with a supported scalar or add an explicit codec"}]
    )
  end

  defp validate_compatibility!(version) when is_binary(version) do
    if Regex.match?(@compatibility_version, version) do
      version
    else
      diagnostic!(
        "E_GODOT_API_VERSION_INVALID",
        "compatibility_minimum must be a Godot major.minor or major.minor.patch version",
        %{value: version}
      )
    end
  end

  defp validate_compatibility!(version) do
    diagnostic!(
      "E_GODOT_API_VERSION_INVALID",
      "compatibility_minimum must be a string",
      %{value: inspect(version)}
    )
  end

  defp validate_boolean!(value, _field) when is_boolean(value), do: value

  defp validate_boolean!(value, field) do
    diagnostic!(
      "E_GODOT_OPTION_INVALID",
      "binding option must be a boolean",
      %{field: field, value: inspect(value)}
    )
  end

  defp validate_initialization_level!(level) when level in @initialization_levels, do: level

  defp validate_initialization_level!(level) do
    diagnostic!(
      "E_GODOT_INITIALIZATION_LEVEL_INVALID",
      "unsupported GDExtension initialization level",
      %{value: inspect(level), supported: @initialization_levels}
    )
  end

  defp method_map(%Method{} = method) do
    %{
      "arguments" => Enum.map(method.arguments, &value_type_name/1),
      "name" => method.name,
      "returns" => value_type_name(method.returns),
      "symbol" => method.symbol
    }
  end

  defp method_json(%Method{} = method) do
    arguments =
      method.arguments
      |> Enum.map(&json_string(value_type_name(&1)))
      |> Enum.intersperse(",")

    [
      "{\"name\":",
      json_string(method.name),
      ",\"arguments\":[",
      arguments,
      "],\"returns\":",
      json_string(value_type_name(method.returns)),
      ",\"symbol\":",
      json_string(method.symbol),
      "}"
    ]
  end

  defp property_map(%Property{} = property) do
    %{
      "getter" => property.getter,
      "name" => property.name,
      "setter" => property.setter,
      "type" => value_type_name(property.type)
    }
  end

  defp property_json(%Property{} = property) do
    [
      "{\"name\":",
      json_string(property.name),
      ",\"type\":",
      json_string(value_type_name(property.type)),
      ",\"getter\":",
      json_string(property.getter),
      ",\"setter\":",
      json_string(property.setter),
      "}"
    ]
  end

  defp signal_map(%Signal{} = signal) do
    %{"arguments" => Enum.map(signal.arguments, &value_type_name/1), "name" => signal.name}
  end

  defp signal_json(%Signal{} = signal) do
    arguments =
      signal.arguments |> Enum.map(&json_string(value_type_name(&1))) |> Enum.intersperse(",")

    ["{\"name\":", json_string(signal.name), ",\"arguments\":[", arguments, "]}"]
  end

  defp virtual_map(%Virtual{} = virtual) do
    %{
      "arguments" => Enum.map(virtual.arguments, &value_type_name/1),
      "name" => virtual.name,
      "returns" => value_type_name(virtual.returns),
      "symbol" => virtual.symbol
    }
  end

  defp virtual_json(%Virtual{} = virtual) do
    arguments =
      virtual.arguments |> Enum.map(&json_string(value_type_name(&1))) |> Enum.intersperse(",")

    [
      "{\"name\":",
      json_string(virtual.name),
      ",\"arguments\":[",
      arguments,
      "],\"returns\":",
      json_string(value_type_name(virtual.returns)),
      ",\"symbol\":",
      json_string(virtual.symbol),
      "}"
    ]
  end

  defp json_string(value), do: JSON.encode!(value)

  defp value_type_name({:object, class_name}), do: "object:#{class_name}"
  defp value_type_name(nil), do: "nil"
  defp value_type_name(value), do: Atom.to_string(value)

  defp default_extension(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp diagnostic!(code, message, context, actions \\ []) do
    raise Diagnostic, code: code, message: message, context: context, actions: actions
  end
end
