defmodule Batata.Library do
  @moduledoc """
  Builds callback-free native shared libraries from a scalar Batata subset.

  Library builds have no implicit entry point, C driver, or term runtime. Each
  exported function is named explicitly and must have a proven scalar i64 ABI;
  unknown or term-shaped signatures fail before native emission.
  """

  alias Batata.{AOT, Export, Frontend, Lower, Symbol}
  alias Beaver.MLIR

  @symbol_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @allowed_options [
    :conversion_plan,
    :dependency_pins,
    :exports,
    :library_name,
    :memory_policy
  ]

  @type export() :: %{function: atom(), arity: non_neg_integer(), symbol: String.t()}
  @type output() :: %{
          object: Path.t(),
          library: Path.t(),
          bundle: Path.t(),
          artifact_index: Path.t(),
          manifest: Path.t()
        }

  @doc "Builds a scalar shared library with an explicit C ABI export surface."
  @spec build(String.t(), Path.t(), MLIR.Context.t(), keyword()) :: output()
  def build(source, output_dir, ctx, opts) when is_binary(source) and is_list(opts) do
    reject_unknown_options!(opts)
    library_name = validate_library_name!(Keyword.fetch!(opts, :library_name))
    dependency_pins = validate_dependency_pins!(Keyword.fetch!(opts, :dependency_pins))
    File.mkdir_p!(output_dir)
    object_path = Path.join(output_dir, "batata-library.o")
    library_path = Path.join(output_dir, AOT.library_name(library_name))

    %{snapshot: snapshot, exports: exports} =
      compile_object!(source, object_path, ctx, Keyword.fetch!(opts, :exports),
        conversion_plan: Keyword.get(opts, :conversion_plan),
        memory_policy: Keyword.get(opts, :memory_policy, :disabled)
      )

    AOT.link_shared_library!(object_path, library_path, exports)

    receipt_exports =
      Enum.map(exports, fn export ->
        %{
          "function" => "#{inspect(snapshot.name)}.#{export.function}/#{export.arity}",
          "symbol" => export.symbol
        }
      end)

    :ok = Export.verify_exact_symbols!(library_path, receipt_exports)

    metadata =
      Export.write!(output_dir, snapshot.name,
        source: source,
        artifact_paths: [library_path, object_path],
        definitions: snapshot.definitions,
        exports: receipt_exports,
        entry: nil,
        bundle_metadata: %{
          "artifact_kind" => "shared-library",
          "compiler_abi" => %{"name" => "batata-scalar-c", "version" => 1},
          "dependency_pins" => dependency_pins
        }
      )

    %{
      object: object_path,
      library: library_path,
      bundle: metadata.bundle,
      artifact_index: metadata.artifact_index,
      manifest: metadata.manifest
    }
  end

  @doc false
  @spec compile_object!(String.t(), Path.t(), MLIR.Context.t(), [export()], keyword()) :: map()
  def compile_object!(source, object_path, ctx, requested_exports, opts \\ []) do
    snapshot = Frontend.from_source(source)
    reject_entry_point!(snapshot)
    exports = normalize_exports!(requested_exports, snapshot)

    signature_overrides =
      Map.new(exports, &{{&1.function, &1.arity}, List.duplicate(:scalar, &1.arity)})

    scalar_result_overrides = MapSet.new(exports, &{&1.function, &1.arity})

    lower_options =
      [conversion_plan: Keyword.get(opts, :conversion_plan)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    module =
      source
      |> Batata.compile(ctx,
        compiler_abi_calls: Keyword.get(opts, :compiler_abi_calls, %{}),
        memory_policy: Keyword.get(opts, :memory_policy, :disabled),
        signature_overrides: signature_overrides,
        scalar_result_overrides: scalar_result_overrides
      )
      |> reject_term_runtime!()
      |> Lower.to_llvm(ctx, lower_options)
      |> MLIR.verify!()

    lowered_ir_digest = digest(MLIR.to_string(module, generic: true))

    File.mkdir_p!(Path.dirname(object_path))
    AOT.emit_object!(module, object_path)

    %{
      snapshot: snapshot,
      exports: exports,
      object: object_path,
      lowered_ir_digest: lowered_ir_digest
    }
  end

  defp reject_entry_point!(%Frontend.Module{definitions: definitions}) do
    if Enum.any?(definitions, &(&1.name in [:main, :batata_main] and &1.arity == 0)) do
      raise ArgumentError, "library source must not define an implicit main entry point"
    end
  end

  defp normalize_exports!(exports, snapshot) when is_list(exports) and exports != [] do
    definitions = MapSet.new(snapshot.definitions, &{&1.name, &1.arity})

    normalized =
      Enum.map(exports, fn export ->
        export = Map.new(export)
        function = Map.fetch!(export, :function)
        arity = Map.fetch!(export, :arity)
        symbol = Map.fetch!(export, :symbol)
        signature = {function, arity}

        unless is_atom(function) and is_integer(arity) and arity >= 0 and
                 is_binary(symbol) and Regex.match?(@symbol_pattern, symbol) do
          raise ArgumentError, "invalid shared-library export: #{inspect(export)}"
        end

        unless MapSet.member?(definitions, signature) do
          raise ArgumentError, "exported function is not defined: #{function}/#{arity}"
        end

        %{
          function: function,
          arity: arity,
          symbol: symbol,
          internal_symbol: Symbol.function(function, arity)
        }
      end)

    duplicate_symbols =
      normalized
      |> Enum.frequencies_by(& &1.symbol)
      |> Enum.filter(fn {_symbol, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_symbols != [] do
      raise ArgumentError, "duplicate shared-library symbols: #{inspect(duplicate_symbols)}"
    end

    Enum.sort_by(normalized, & &1.symbol)
  end

  defp normalize_exports!(exports, _snapshot) do
    raise ArgumentError,
          "shared-library exports must be a non-empty list, got: #{inspect(exports)}"
  end

  defp reject_term_runtime!(module) do
    ir = MLIR.to_string(module)

    if ir =~ "!ex.term" or ir =~ ~s["ex.term] do
      raise ArgumentError,
            "scalar library target cannot link the Batata term runtime; refine the source ABI"
    end

    module
  end

  defp validate_library_name!(name)
       when is_binary(name) and byte_size(name) > 0 do
    if Regex.match?(@symbol_pattern, name),
      do: name,
      else: raise(ArgumentError, "invalid shared-library name: #{inspect(name)}")
  end

  defp validate_library_name!(name),
    do: raise(ArgumentError, "invalid shared-library name: #{inspect(name)}")

  defp validate_dependency_pins!(pins) when is_map(pins) and map_size(pins) > 0 do
    if Enum.all?(pins, fn {key, value} ->
         is_binary(key) and byte_size(key) > 0 and is_binary(value) and byte_size(value) > 0
       end) do
      pins
    else
      raise ArgumentError, "dependency pins must be a non-empty string map"
    end
  end

  defp validate_dependency_pins!(_pins),
    do: raise(ArgumentError, "dependency pins must be a non-empty string map")

  defp reject_unknown_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "shared-library options must be a keyword list"
    end

    case Keyword.keys(opts) -- @allowed_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown shared-library options: #{inspect(unknown)}"
    end
  end

  defp digest(value) do
    "sha256:" <>
      (value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
  end
end
