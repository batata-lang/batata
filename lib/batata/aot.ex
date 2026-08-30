defmodule Batata.AOT do
  @moduledoc false

  @doc false
  @spec emit_object!(Beaver.MLIR.Module.t(), Path.t()) :: Path.t()
  def emit_object!(module, object_path) do
    llvm_config =
      System.get_env("LLVM_CONFIG_PATH") ||
        raise "LLVM_CONFIG_PATH is required to emit a relocatable AOT object"

    llvm_bin = Path.dirname(llvm_config)
    mlir_translate = require_tool!(Path.join(llvm_bin, "mlir-translate"), "mlir-translate")
    mlir_path = Path.rootname(object_path) <> ".mlir"
    llvm_ir_path = Path.rootname(object_path) <> ".ll"

    File.write!(mlir_path, Beaver.MLIR.to_string(module))

    try do
      run_tool!(mlir_translate, ["--mlir-to-llvmir", mlir_path, "-o", llvm_ir_path])

      {compiler, compiler_prefix, pic_args} = object_compiler!()

      run_tool!(
        compiler,
        compiler_prefix ++ ["-c", "-O2"] ++ pic_args ++ [llvm_ir_path, "-o", object_path]
      )
    after
      File.rm(mlir_path)
      File.rm(llvm_ir_path)
    end

    object_path
  end

  @doc false
  @spec link_shared_library!(Path.t(), Path.t(), [map()], keyword()) :: Path.t()
  def link_shared_library!(object_path, library_path, exports, opts \\ []) do
    {compiler, compiler_prefix} = shared_library_compiler!()
    shim_path = Path.join(Path.dirname(library_path), ".batata-library-exports.c")
    public_symbols = Keyword.get(opts, :public_symbols, Enum.map(exports, & &1.symbol))
    extra_sources = Keyword.get(opts, :extra_sources, [])
    compiler_args = Keyword.get(opts, :compiler_args, [])
    {export_args, export_control_path} = export_control(public_symbols, library_path)
    File.write!(shim_path, export_shim(exports, public_symbols))

    try do
      run_tool!(
        compiler,
        compiler_prefix ++
          shared_library_args() ++
          export_args ++
          compiler_args ++
          ["-fPIC", "-O2", shim_path, object_path] ++
          extra_sources ++ ["-o", library_path]
      )
    after
      File.rm(shim_path)
      if export_control_path, do: File.rm(export_control_path)
    end

    library_path
  end

  @doc false
  @spec library_name(String.t()) :: String.t()
  def library_name(name) do
    case :os.type() do
      {:win32, _} -> name <> ".dll"
      {:unix, :darwin} -> "lib" <> name <> ".dylib"
      _ -> "lib" <> name <> ".so"
    end
  end

  defp export_shim(exports, public_symbols) do
    public_symbols = MapSet.new(public_symbols)
    declarations = Enum.map_join(exports, "\n", &export_declaration/1)

    wrappers =
      Enum.map_join(exports, "\n\n", fn export ->
        export_wrapper(export, MapSet.member?(public_symbols, export.symbol))
      end)

    """
    #include <stdint.h>

    #if defined(_WIN32)
    #define BATATA_EXPORT __declspec(dllexport)
    #else
    #define BATATA_EXPORT __attribute__((visibility("default")))
    #endif

    #{declarations}

    #{wrappers}
    """
  end

  defp export_declaration(%{arity: arity, internal_symbol: internal}) do
    "extern int64_t #{internal}(#{c_parameters(arity)});"
  end

  defp export_wrapper(
         %{arity: arity, internal_symbol: internal, symbol: symbol},
         public?
       ) do
    visibility = if public?, do: "BATATA_EXPORT ", else: ""

    """
    #{visibility}int64_t #{symbol}(#{c_parameters(arity)}) {
      return #{internal}(#{c_arguments(arity)});
    }
    """
    |> String.trim()
  end

  defp c_parameters(0), do: "void"

  defp c_parameters(arity) do
    0..(arity - 1)
    |> Enum.map_join(", ", &"int64_t arg#{&1}")
  end

  defp c_arguments(0), do: ""
  defp c_arguments(arity), do: Enum.map_join(0..(arity - 1), ", ", &"arg#{&1}")

  defp object_compiler! do
    case :os.type() do
      {:win32, _} ->
        {require_tool!(System.find_executable("clang"), "clang"), [], []}

      {:unix, _} ->
        {require_tool!(System.find_executable("zig"), "zig"), ["cc"], ["-fPIC"]}
    end
  end

  defp shared_library_args do
    case :os.type() do
      {:unix, :darwin} -> ["-dynamiclib"]
      _ -> ["-shared"]
    end
  end

  defp shared_library_compiler! do
    case :os.type() do
      {:unix, :darwin} ->
        {require_tool!(System.find_executable("cc"), "cc"), []}

      _ ->
        {require_tool!(System.find_executable("zig"), "zig"), ["cc"]}
    end
  end

  defp export_control(symbols, library_path) do
    case :os.type() do
      {:unix, :darwin} ->
        args = Enum.map(symbols, &"-Wl,-exported_symbol,_#{&1}")
        {args, nil}

      {:win32, _} ->
        {Enum.map(symbols, &"-Wl,--export=#{&1}"), nil}

      _ ->
        path = Path.join(Path.dirname(library_path), ".batata-library-exports.map")
        globals = Enum.map_join(symbols, "\n", &"    #{&1};")
        File.write!(path, "{\n  global:\n#{globals}\n  local: *;\n};\n")
        {["-Wl,--version-script=#{path}"], path}
    end
  end

  defp require_tool!(path, name) when is_binary(path) do
    if File.regular?(path), do: path, else: raise("#{name} not found at #{path}")
  end

  defp require_tool!(nil, name), do: raise("#{name} not found on PATH")

  defp run_tool!(executable, arguments) do
    case System.cmd(executable, arguments, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "#{Path.basename(executable)} failed (#{status}):\n#{output}"
    end
  end
end
