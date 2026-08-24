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

  @schema 1
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
    :methods
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
          methods: [Method.t()]
        }

  @doc false
  @spec new!(module(), keyword(), [{term(), keyword()}], [{term(), keyword()}], [
          {atom(), non_neg_integer()}
        ]) :: t()
  def new!(module, extension_options, class_declarations, method_declarations, definitions) do
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

    %__MODULE__{
      schema: @schema,
      module: module,
      extension: extension,
      entry_symbol: entry_symbol,
      compatibility_minimum: compatibility_minimum,
      reloadable: reloadable,
      initialization_level: initialization_level,
      class: class,
      methods: methods
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
      "module" => inspect(plan.module),
      "reloadable" => plan.reloadable,
      "schema" => plan.schema
    }
  end

  @doc "Encodes the plan with fixed field ordering for replayable digests."
  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = plan) do
    methods = plan.methods |> Enum.map(&method_json/1) |> Enum.intersperse(",")

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
