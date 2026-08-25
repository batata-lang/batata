defmodule Batata do
  @moduledoc """
  An Elixir-to-native compiler built on [Beaver](https://github.com/beaver-lodge/beaver)
  and the Slang-defined `ex` dialect.

  The frontend boundary lowers an expanded module snapshot to `ex` IR, then
  information-preserving IR-to-IR transforms run (`Batata.Transform`, e.g.
  scalar call inlining), then `ex` lowers to `func`/`arith`/`scf`/`cf` and
  finally to LLVM via `Beaver.MLIR.Conversion.Plan`. Both JIT (`execute/2`)
  and AOT (`build/4`) execution are supported.
  """

  alias Batata.Lower
  alias Beaver.MLIR
  alias Beaver.Native
  alias Beaver.Native.I64

  defmodule ResultError do
    @moduledoc "Raised when a native result handle cannot be materialized safely."
    defexception [:message]
  end

  defmodule UnsupportedFeatureError do
    @moduledoc "Raised when native execution reaches a deliberately unsupported value domain."
    defexception [:message, :reason, :value]
  end

  @doc """
  Parses and lowers Elixir source into a verified `builtin.module` of `ex`
  operations.
  """
  @spec compile(String.t() | Batata.Frontend.Module.t(), MLIR.Context.t(), keyword()) ::
          MLIR.Module.t()
  def compile(source, ctx, opts \\ []) do
    validate_reduction_budget!(opts[:reduction_budget])

    {snapshot, atom_table} =
      case source do
        %Batata.Frontend.Module{} = mod ->
          validate_parallel_receive_sites!(mod, Keyword.get(opts, :workers, 1))
          {mod, Keyword.get(opts, :atom_table, literal_atom_table(mod))}

        source when is_binary(source) ->
          validate_parallel_receive_sites!(source, Keyword.get(opts, :workers, 1))
          {Batata.Frontend.from_source(source), literal_atom_table(source)}
      end

    module =
      snapshot
      |> Batata.Lift.module_to_ir(
        [
          ctx: ctx,
          atom_table: atom_table,
          reduction_budget: opts[:reduction_budget],
          reduction_batching: opts[:reduction_batching],
          workers: Keyword.get(opts, :workers, 1),
          process_cap: opts[:process_cap]
        ] ++ opts
      )
      |> Beaver.Deferred.resolve(ctx)

    module =
      module
      |> Batata.Transform.run!([
        Batata.Transform.InlineScalarCalls,
        Batata.Transform.ExpandCase
      ])
      |> MLIR.verify!()

    Batata.Memory.verify!(module,
      module: snapshot.name,
      source: source,
      policy: Keyword.get(opts, :memory_policy, :disabled),
      dependency_lock: opts[:memory_dependency_lock],
      contracts: Keyword.get(opts, :memory_contracts, %{}),
      quota_bytes: opts[:memory_quota_bytes]
    )

    module
  end

  # The reduction budget drives the batched tick (`ex.reduction_tick(budget)`
  # once per budget iterations, #41): it must be a positive integer when set.
  defp validate_reduction_budget!(nil), do: :ok

  defp validate_reduction_budget!(budget) when is_integer(budget) and budget > 0, do: :ok

  defp validate_reduction_budget!(budget) do
    raise ArgumentError,
          "reduction_budget must be a positive integer or nil, got: #{inspect(budget)}"
  end

  # The current continuation ABI has one slot per actor. With multiple native
  # workers, a later blocking receive can suspend after an earlier receive has
  # completed, then re-enter the function at that earlier site. Fail before
  # entering the JIT instead of allowing a wrong result, hang, or a timeout-
  # induced VM crash. The serial scheduler remains the supported path for
  # multiple receive sites until continuations carry a stable site identity.
  defp validate_parallel_receive_sites!(_source, workers) when workers <= 1, do: :ok

  defp validate_parallel_receive_sites!(source, workers) do
    receive_sites = count_receive_sites(source)

    if receive_sites > 1 do
      raise ArgumentError,
            "parallel workers currently support at most one receive site per module; " <>
              "got #{receive_sites} with workers: #{workers}"
    end
  end

  defp count_receive_sites(source) when is_binary(source) do
    source
    |> Code.string_to_quoted!()
    |> count_receive_sites_in_ast()
  end

  defp count_receive_sites(%Batata.Frontend.Module{definitions: definitions}) do
    Enum.reduce(definitions, 0, fn definition, count ->
      count + count_definition_receive_sites(definition)
    end)
  end

  defp count_definition_receive_sites(definition) do
    Enum.reduce(definition.clauses, 0, fn clause, count ->
      count + count_clause_receive_sites(clause)
    end)
  end

  defp count_clause_receive_sites(clause) do
    [clause.patterns, clause.guard_ast, clause.body_ast]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(0, fn ast, count -> count + count_receive_sites_in_ast(ast) end)
  end

  defp count_receive_sites_in_ast(ast) do
    ast
    |> Macro.prewalk(0, fn
      {:receive, _, _} = node, count -> {node, count + 1}
      node, count -> {node, count}
    end)
    |> elem(1)
  end

  @doc """
  Parses Elixir source and lowers it all the way to LLVM dialect IR.
  """
  @spec to_llvm(String.t(), MLIR.Context.t()) :: MLIR.Module.t()
  def to_llvm(source, ctx) do
    source
    |> compile(ctx)
    |> Lower.to_llvm(ctx)
    |> MLIR.verify!()
  end

  @doc """
  Parses Elixir source, lowers it to LLVM and executes `main` through the
  MLIR JIT, returning its value.

  Set `workers: n` to run independent actors on a fixed pool of `n` OS
  workers. The default is `1`, preserving the deterministic serial scheduler.
  Set `process_cap: n` (1..4096, default 256) to size the actor process
  table's initial allocation; it grows dynamically on spawn (#50 stage 2), so
  `spawn` only fails on allocation failure.

  The JIT engine and module are destroyed before returning.
  """
  @spec execute(String.t(), MLIR.Context.t()) :: term()
  def execute(source, ctx, opts \\ []) do
    lock = {{__MODULE__, :execution_engine}, self()}
    :global.trans(lock, fn -> execute_isolated(source, ctx, opts) end)
  end

  # MLIR's process-global execution-engine symbol registry can resolve the
  # identically named C wrappers from a concurrently active engine. Keep the
  # complete engine lifetime atomic so a result handle is always inspected by
  # the engine which created it. Native actors inside one execution remain
  # parallel; only independent host engine lifetimes are serialized. The
  # caller pid is the requester component of the global lock id; sharing a
  # constant requester would make concurrent callers look reentrant.
  defp execute_isolated(source, ctx, opts) do
    module =
      source
      |> compile(ctx, opts)
      |> Lower.to_llvm(ctx, c_interface: true)
      |> MLIR.verify!()

    jit = MLIR.ExecutionEngine.create!(module, execution_engine_opts(module))

    try do
      handle = invoke_i64(jit, "main", [], dirty: :cpu_bound)

      if handle == -2 do
        raise ResultError, "native arena allocation failed"
      end

      if handle == 0 do
        raise ResultError, "native result registry is full"
      end

      try do
        case invoke_i64(jit, "__batata_result_exception_kind", [handle]) do
          0 -> materialize_result(jit, handle, source)
          kind -> materialize_exception(jit, handle, kind, source)
        end
      after
        invoke_i64(jit, "__batata_result_destroy", [handle])
      end
    after
      MLIR.ExecutionEngine.destroy(jit)
      MLIR.Module.destroy(module)
    end
  end

  defp materialize_exception(jit, handle, kind, source) do
    word = invoke_i64(jit, "__batata_result_exception_reason", [handle])
    term_kind = invoke_i64(jit, "__batata_result_term_kind", [handle, word])
    reason = materialize_word(jit, handle, word, term_kind, literal_atom_table(source))

    case {kind, reason} do
      {1, term} ->
        raise CaseClauseError, term: term

      {2, {function, arity, args}} ->
        raise FunctionClauseError,
          module: Batata.Frontend.from_source(source).name,
          function: function,
          arity: arity,
          args: args

      {2, {module, function, arity, args}} ->
        raise FunctionClauseError,
          module: module,
          function: function,
          arity: arity,
          args: args

      {3, {reason, value}} when reason in [:unknown_atom, :unsupported_type] ->
        raise UnsupportedFeatureError,
          reason: reason,
          value: value,
          message: "Kernel.to_string/1 native subset rejected #{reason}: #{inspect(value)}"

      {4, {key, term}} ->
        raise KeyError, key: key, term: term

      {5, term} ->
        raise BadMapError, term: term

      {6, message} when is_binary(message) ->
        raise ArgumentError, message: message

      _ ->
        raise ResultError, "unknown native exception kind #{kind}: #{inspect(reason)}"
    end
  end

  defp materialize_result(jit, handle, source) do
    kind = invoke_i64(jit, "__batata_result_root_kind", [handle])
    word = invoke_i64(jit, "__batata_result_root_word", [handle])
    atoms = literal_atom_table(source)

    cond do
      kind < 0 -> raise ResultError, "native result handle is stale"
      kind == 0 -> materialize_scalar_root(word, atoms)
      true -> materialize_word(jit, handle, word, kind, atoms)
    end
  end

  # A root which is not heap-owned may be either a legacy unboxed integer or
  # an immediate term word. Decode atoms known from the source (including nil)
  # while preserving scalar compatibility for arithmetic entry points.
  defp materialize_scalar_root(word, atoms), do: Map.get(atoms, word, word)

  defp materialize_word(_jit, _handle, word, 0, _atoms), do: div(word, 8)
  defp materialize_word(_jit, _handle, 1, 1, _atoms), do: nil

  defp materialize_word(_jit, _handle, word, 1, atoms) do
    Map.get_lazy(atoms, word, fn ->
      raise ResultError, "unknown native atom word #{word}"
    end)
  end

  defp materialize_word(jit, handle, word, 2, atoms) do
    length = result_length(jit, handle, word)

    0..(length - 1)//1
    |> Enum.map(&materialize_child(jit, handle, word, &1, atoms))
    |> List.to_tuple()
  end

  defp materialize_word(jit, handle, word, 3, atoms) do
    length = result_length(jit, handle, word)
    Enum.map(0..(length - 1)//1, &materialize_child(jit, handle, word, &1, atoms))
  end

  defp materialize_word(jit, handle, word, 4, atoms) do
    length = result_length(jit, handle, word)

    0..(length - 1)//1
    |> Enum.map(fn index ->
      key = materialize_child(jit, handle, word, index * 2, atoms)
      value = materialize_child(jit, handle, word, index * 2 + 1, atoms)
      {key, value}
    end)
    |> Map.new()
  end

  defp materialize_word(jit, handle, word, 5, _atoms) do
    length = result_length(jit, handle, word)

    0..(length - 1)//1
    |> Enum.map(&invoke_i64(jit, "__batata_result_term_get", [handle, word, &1]))
    |> :erlang.list_to_binary()
  end

  defp materialize_word(_jit, _handle, _word, 6, _atoms) do
    raise ResultError, "native closures cannot cross the host result boundary"
  end

  defp materialize_word(jit, handle, word, 7, _atoms) do
    bits = invoke_i64(jit, "__batata_result_term_get", [handle, word, 0])
    <<value::float-64-native>> = <<bits::signed-64-native>>
    value
  end

  defp materialize_word(_jit, _handle, _word, kind, _atoms) do
    raise ResultError, "invalid native term kind #{kind}"
  end

  defp materialize_child(jit, handle, parent, index, atoms) do
    word = invoke_i64(jit, "__batata_result_term_get", [handle, parent, index])
    kind = invoke_i64(jit, "__batata_result_term_kind", [handle, word])
    materialize_word(jit, handle, word, kind, atoms)
  end

  defp result_length(jit, handle, word) do
    case invoke_i64(jit, "__batata_result_term_length", [handle, word]) do
      length when length >= 0 -> length
      _ -> raise ResultError, "native term does not have a readable length"
    end
  end

  defp literal_atom_table(%Batata.Frontend.Module{} = snapshot) do
    atoms =
      snapshot
      |> Map.fetch!(:definitions)
      |> Enum.reduce(%{}, fn definition, acc ->
        definition.clauses
        |> Enum.reduce(Map.put(acc, atom_word(definition.name), definition.name), fn clause,
                                                                                     clause_atoms ->
          ([clause.patterns, clause.body_ast] ++ List.wrap(clause.guard_ast))
          |> Enum.reduce(clause_atoms, &collect_literal_atoms/2)
        end)
      end)

    atoms = add_struct_schema_atoms(atoms, snapshot.struct_schema)

    snapshot.struct_schemas
    |> Enum.reduce(atoms, fn {_mod, schema}, acc -> add_struct_schema_atoms(acc, schema) end)
    |> add_common_atoms()
  end

  defp literal_atom_table(source) when is_binary(source) do
    snapshot = Batata.Frontend.from_source(source)

    atoms =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(%{}, fn
        atom, acc when is_atom(atom) and not is_nil(atom) ->
          {atom, Map.put(acc, atom_word(atom), atom)}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    atoms =
      snapshot
      |> Map.fetch!(:definitions)
      |> Enum.reduce(atoms, fn definition, acc ->
        definition.clauses
        |> Enum.reduce(Map.put(acc, atom_word(definition.name), definition.name), fn clause,
                                                                                     clause_atoms ->
          ([clause.patterns, clause.body_ast] ++ List.wrap(clause.guard_ast))
          |> Enum.reduce(clause_atoms, &collect_literal_atoms/2)
        end)
      end)

    atoms = add_struct_schema_atoms(atoms, snapshot.struct_schema)

    # `nil` also appears pervasively as quoted AST metadata/context. Only
    # expose its immediate word when the source contains the literal token;
    # otherwise an unboxed scalar result of 1 must remain the integer 1.
    atoms = if Regex.match?(~r/\bnil\b/, source), do: Map.put(atoms, 1, nil), else: atoms

    add_common_atoms(atoms)
  end

  defp collect_literal_atoms({:__aliases__, _metadata, parts}, atoms) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = Elixir.Module.concat(parts)
      Map.put(atoms, atom_word(module), module)
    else
      atoms
    end
  end

  defp collect_literal_atoms({name, metadata, arguments}, atoms)
       when is_atom(name) and is_list(metadata) and is_list(arguments) do
    Enum.reduce(arguments, atoms, &collect_literal_atoms/2)
  end

  defp collect_literal_atoms(atom, atoms) when is_atom(atom) do
    Map.put(atoms, atom_word(atom), atom)
  end

  defp collect_literal_atoms(list, atoms) when is_list(list) do
    Enum.reduce(list, atoms, &collect_literal_atoms/2)
  end

  defp collect_literal_atoms(tuple, atoms) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(atoms, &collect_literal_atoms/2)
  end

  defp collect_literal_atoms(_other, atoms), do: atoms

  defp add_common_atoms(atoms) do
    atoms
    |> Map.put(atom_word(true), true)
    |> Map.put(atom_word(false), false)
    # Enumerable.List.reduce/3 lowering synthesizes these protocol states;
    # keep them materializable even when a particular input branch does not
    # spell every result atom in source.
    |> Map.put(atom_word(:cont), :cont)
    |> Map.put(atom_word(:halt), :halt)
    |> Map.put(atom_word(:suspend), :suspend)
    |> Map.put(atom_word(:done), :done)
    |> Map.put(atom_word(:halted), :halted)
    |> Map.put(atom_word(:suspended), :suspended)
    |> Map.put(atom_word(String), String)
    |> Map.put(atom_word(:printable?), :printable?)
    |> Map.put(atom_word(:nomatch), :nomatch)
    |> Map.put(atom_word(:unknown_atom), :unknown_atom)
    |> Map.put(atom_word(:unsupported_type), :unsupported_type)
  end

  defp add_struct_schema_atoms(atoms, nil), do: atoms

  defp add_struct_schema_atoms(atoms, %Batata.Frontend.StructSchema{} = schema) do
    schema_atoms =
      [schema.module, :__struct__] ++
        Enum.map(schema.fields, &elem(&1, 0)) ++
        if(schema.kind == :exception, do: [:__exception__], else: [])

    Enum.reduce(schema_atoms, atoms, fn atom, acc -> Map.put(acc, atom_word(atom), atom) end)
  end

  defp atom_word(atom), do: (16 + :erlang.phash2(atom)) * 8 + 1

  defp invoke_i64(jit, name, arguments, opts \\ []) do
    native_arguments = Enum.map(arguments, &I64.make/1)
    result = I64.make(0)
    MLIR.ExecutionEngine.invoke!(jit, name, native_arguments, result, opts)
    Native.to_term(result)
  end

  # Term ops lower to `ex.term.*` calls; when they are present the JIT must be
  # able to resolve them, so the Zig term runtime shared library is attached.
  defp execution_engine_opts(module) do
    if MLIR.to_string(module) =~ "ex.term." do
      [shared_lib_paths: [Batata.TermRuntime.ensure_built!()]]
    else
      []
    end
  end

  @doc """
  Compiles Elixir source to a static library and a C driver.

  The entry function `main` is renamed to `batata_main` in the generated
  object so the driver can call it without colliding with the C entry point.
  Returns a map with the archive, driver and object paths.

  Link the driver against the archive and run it:

      cc driver.c libMath.a -o run_math
  """
  @spec build(String.t(), Path.t(), MLIR.Context.t(), keyword()) :: %{
          optional(:memory_plan) => Path.t(),
          optional(:memory_diagnostics) => Path.t(),
          archive: Path.t(),
          driver: Path.t(),
          object: Path.t(),
          runtime_lib: Path.t(),
          bundle: Path.t(),
          artifact_index: Path.t(),
          manifest: Path.t()
        }
  def build(source, output_dir, ctx, opts \\ []) do
    validate_reduction_budget!(opts[:reduction_budget])

    snapshot =
      source
      |> Batata.Frontend.from_source()
      |> rename_entry(:batata_main)

    ex_module =
      snapshot
      |> Batata.Lift.module_to_ir(
        opts
        |> Keyword.put(:ctx, ctx)
        |> Keyword.put(:atom_table, literal_atom_table(source))
      )
      |> Beaver.Deferred.resolve(ctx)
      |> Batata.Transform.run!([
        Batata.Transform.InlineScalarCalls,
        Batata.Transform.ExpandCase
      ])
      |> MLIR.verify!()

    memory_plan =
      Batata.Memory.verify!(ex_module,
        module: snapshot.name,
        source: source,
        policy: Keyword.get(opts, :memory_policy, :disabled),
        dependency_lock: opts[:memory_dependency_lock],
        contracts: Keyword.get(opts, :memory_contracts, %{}),
        quota_bytes: opts[:memory_quota_bytes]
      )

    module =
      ex_module
      |> Batata.Lower.to_llvm(ctx)
      |> MLIR.verify!()

    File.mkdir_p!(output_dir)

    object_path = Path.join(output_dir, "batata.o")
    archive_path = Path.join(output_dir, "lib#{snapshot.name}.a")
    driver_path = Path.join(output_dir, "driver.c")
    runtime_lib = Batata.TermRuntime.ensure_static_built!()
    runtime_lib_copy = Path.join(output_dir, Path.basename(runtime_lib))
    File.cp!(runtime_lib, runtime_lib_copy)

    emit_aot_object!(module, object_path)

    archive!(archive_path, object_path)
    File.write!(driver_path, driver_source())

    memory_artifacts =
      case memory_plan do
        :disabled -> %{}
        %Batata.Memory.Plan{} = plan -> Batata.Memory.write_artifacts!(output_dir, plan)
      end

    artifact_paths =
      [archive_path, object_path, driver_path, runtime_lib_copy]
      |> Kernel.++(Map.values(memory_artifacts))
      |> Enum.sort()

    metadata =
      Batata.Export.write!(output_dir, snapshot.name,
        source: source,
        artifact_paths: artifact_paths,
        definitions: snapshot.definitions,
        entry_name: :main
      )

    Map.merge(
      %{
        archive: archive_path,
        driver: driver_path,
        object: object_path,
        runtime_lib: runtime_lib_copy,
        bundle: metadata.bundle,
        artifact_index: metadata.artifact_index,
        manifest: metadata.manifest
      },
      memory_artifacts
    )
  end

  defp rename_entry(%Batata.Frontend.Module{} = snapshot, entry) do
    %{
      snapshot
      | definitions:
          Enum.map(snapshot.definitions, fn
            %Batata.Frontend.Definition{name: :main} = definition ->
              %{definition | name: entry}

            definition ->
              definition
          end)
    }
  end

  defp archive!(archive_path, object_path) do
    ar = System.find_executable("ar") || raise "ar not found on PATH"
    {_output, 0} = System.cmd(ar, ["rcs", archive_path, object_path], stderr_to_stdout: true)
    archive_path
  end

  defp emit_aot_object!(module, object_path) do
    llvm_config =
      System.get_env("LLVM_CONFIG_PATH") ||
        raise "LLVM_CONFIG_PATH is required to emit a relocatable AOT object"

    llvm_bin = Path.dirname(llvm_config)
    mlir_translate = require_tool!(Path.join(llvm_bin, "mlir-translate"), "mlir-translate")
    mlir_path = Path.rootname(object_path) <> ".mlir"
    llvm_ir_path = Path.rootname(object_path) <> ".ll"

    File.write!(mlir_path, MLIR.to_string(module))

    run_tool!(mlir_translate, ["--mlir-to-llvmir", mlir_path, "-o", llvm_ir_path])

    {compiler, compiler_prefix, pic_args} =
      case :os.type() do
        {:win32, _} ->
          {require_tool!(System.find_executable("clang"), "clang"), [], []}

        {:unix, _} ->
          {require_tool!(System.find_executable("zig"), "zig"), ["cc"], ["-fPIC"]}
      end

    run_tool!(
      compiler,
      compiler_prefix ++ ["-c", "-O2"] ++ pic_args ++ [llvm_ir_path, "-o", object_path]
    )

    File.rm!(mlir_path)
    File.rm!(llvm_ir_path)
    object_path
  end

  defp require_tool!(path, name) when is_binary(path) do
    if File.regular?(path), do: path, else: raise("#{name} not found at #{path}")
  end

  defp require_tool!(nil, name), do: raise("#{name} not found on PATH")

  defp run_tool!(executable, arguments) do
    case System.cmd(executable, arguments, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "#{Path.basename(executable)} failed with exit status #{status}:\n#{output}"
    end
  end

  defp driver_source do
    """
    #include <stdint.h>
    #include <stdio.h>

    extern int64_t batata_main(void);
    extern int64_t __batata_result_destroy(int64_t);
    extern int64_t __batata_result_root_kind(int64_t);
    extern int64_t __batata_result_root_word(int64_t);
    extern int64_t __batata_result_term_kind(int64_t, int64_t);
    extern int64_t __batata_result_term_length(int64_t, int64_t);
    extern int64_t __batata_result_term_get(int64_t, int64_t, int64_t);

    static int print_term(int64_t handle, int64_t word, int64_t kind) {
      int64_t length;
      if (kind == 0) return printf("%lld", (long long)(word / 8)) < 0 ? -1 : 0;
      if (kind == 1) {
        if (word == 1) return printf("nil") < 0 ? -1 : 0;
        return printf("#Atom<%lld>", (long long)word) < 0 ? -1 : 0;
      }
      if (kind == 6) return -1;
      length = __batata_result_term_length(handle, word);
      if (length < 0) return -1;
      if (kind == 5) {
        if (putchar('"') == EOF) return -1;
        for (int64_t i = 0; i < length; i++) {
          int byte = (int)__batata_result_term_get(handle, word, i);
          if (byte == '"' || byte == '\\\\') putchar('\\\\');
          if (putchar(byte) == EOF) return -1;
        }
        return putchar('"') == EOF ? -1 : 0;
      }
      if (kind == 2) putchar('{');
      else if (kind == 3) putchar('[');
      else if (kind == 4) fputs("%{", stdout);
      for (int64_t i = 0; i < length; i++) {
        if (i > 0) fputs(", ", stdout);
        if (kind == 4) {
          int64_t key = __batata_result_term_get(handle, word, i * 2);
          int64_t value = __batata_result_term_get(handle, word, i * 2 + 1);
          if (print_term(handle, key, __batata_result_term_kind(handle, key)) < 0) return -1;
          fputs(" => ", stdout);
          if (print_term(handle, value, __batata_result_term_kind(handle, value)) < 0) return -1;
        } else {
          int64_t child = __batata_result_term_get(handle, word, i);
          if (print_term(handle, child, __batata_result_term_kind(handle, child)) < 0) return -1;
        }
      }
      return putchar(kind == 2 || kind == 4 ? '}' : ']') == EOF ? -1 : 0;
    }

    int main(void) {
      int status = 0;
      int64_t handle = batata_main();
      if (handle == -2) return 6;
      if (handle == 0) return 2;
      int64_t kind = __batata_result_root_kind(handle);
      int64_t word = __batata_result_root_word(handle);
      if (kind < 0) status = 3;
      else if (kind == 0) status = printf("%lld", (long long)word) < 0 ? 4 : 0;
      else status = print_term(handle, word, kind) < 0 ? 4 : 0;
      if (__batata_result_destroy(handle) < 0 && status == 0) status = 5;
      if (status == 0) putchar('\\n');
      return status;
    }
    """
  end
end
