defmodule Batata.ExConversionKernel.Provider do
  @moduledoc """
  Selects Batata's fail-closed native Ex conversion provider.

  Beaver owns the provider-neutral manifest, loader, and trampoline. Batata
  owns production policy: a configured Stage 2 artifact is the only native
  production path, while the C++ Stage 0 seed must be requested explicitly by
  bootstrap tooling.
  """

  alias Batata.Memory
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest
  alias Beaver.MLIR.Conversion.Plan

  @required_options [
    :beaver_revision,
    :dialect_schema_digest,
    :runtime_abi_digest,
    :target
  ]

  defmodule ConfigurationError do
    @moduledoc "Raised before conversion when the production kernel is not configured."
    defexception [:code, :message]
  end

  @doc "Builds a conversion plan for one verified Ex conversion kernel artifact."
  @spec plan!(KernelManifest.t(), Path.t(), keyword()) :: Plan.t()
  def plan!(%KernelManifest{} = manifest, artifact, opts)
      when is_binary(artifact) and is_list(opts) do
    reject_options!(opts)
    ^manifest = KernelManifest.verify_artifact!(manifest, artifact)

    Plan.new(mode: :full, folding_mode: :after_patterns, build_materializations: true)
    |> Plan.add_legal_dialect("builtin")
    |> Plan.add_legal_dialect("func")
    |> Plan.add_legal_dialect("arith")
    |> Plan.add_legal_dialect("cf")
    |> Plan.add_legal_dialect("scf")
    |> Plan.add_legal_dialect("llvm")
    |> Plan.add_illegal_dialect("ex")
    |> Plan.add_conversion_map(~w(!ex.term !ex.bound !ex.unbound), "i64")
    |> Plan.add_external_pattern_population(manifest, artifact,
      expected: [
        beaver_revision: Keyword.fetch!(opts, :beaver_revision),
        dialect_schema_digest: Keyword.fetch!(opts, :dialect_schema_digest),
        runtime_abi_digest: Keyword.fetch!(opts, :runtime_abi_digest),
        target: Keyword.fetch!(opts, :target),
        capabilities: manifest.capabilities
      ]
    )
  end

  @doc "Builds the production plan and rejects bootstrap-generation artifacts."
  @spec production_plan!(KernelManifest.t(), Path.t(), keyword()) :: Plan.t()
  def production_plan!(%KernelManifest{} = manifest, artifact, opts) do
    require_stage2!(manifest)
    plan!(manifest, artifact, opts)
  end

  @doc "Loads the production manifest and artifact from Batata application config."
  @spec configured_plan!() :: Plan.t()
  def configured_plan! do
    config =
      Application.get_env(:batata, :ex_conversion_kernel) ||
        configuration_error!(
          :production_kernel_missing,
          "native production Ex conversion kernel is not configured"
        )

    unless Keyword.keyword?(config) do
      configuration_error!(
        :invalid_production_kernel_config,
        ":batata, :ex_conversion_kernel must be a keyword list"
      )
    end

    manifest_path = fetch_config!(config, :manifest)
    artifact = fetch_config!(config, :artifact)
    expected = fetch_config!(config, :expected)

    manifest =
      case File.read(manifest_path) do
        {:ok, bytes} ->
          KernelManifest.decode!(bytes)

        {:error, reason} ->
          configuration_error!(
            :production_manifest_unreadable,
            "cannot read production Ex conversion kernel manifest: #{inspect(reason)}"
          )
      end

    production_plan!(manifest, artifact, expected)
  end

  @doc "Profiles a Stage 2 production conversion and writes its callback receipt."
  @spec profile!(
          KernelManifest.t(),
          Path.t(),
          MLIR.Conversion.conversion_ir(),
          Path.t(),
          keyword()
        ) :: {MLIR.Conversion.conversion_ir(), map()}
  def profile!(%KernelManifest{} = manifest, artifact, ir, receipt_path, opts)
      when is_binary(artifact) and is_binary(receipt_path) and is_list(opts) do
    {converted, conversion} =
      manifest
      |> production_plan!(artifact, opts)
      |> Plan.profile!(ir)

    callback_count = get_in(conversion, ["beam", "callback_count"])

    unless callback_count == 0 and conversion["callbacks"] == [] do
      raise "production Ex conversion kernel crossed the BEAM callback boundary"
    end

    receipt = %{
      "schema_version" => 1,
      "provider" => manifest.provider,
      "kernel_identity" => KernelManifest.identity_digest(manifest),
      "artifact_sha256" => manifest.artifact_sha256,
      "bootstrap" => manifest.bootstrap,
      "callback_free" => true,
      "conversion" => conversion
    }

    File.mkdir_p!(Path.dirname(receipt_path))
    File.write!(receipt_path, Memory.canonical_json(receipt) <> "\n")
    {converted, receipt}
  end

  defp require_stage2!(%KernelManifest{bootstrap: bootstrap}) do
    unless bootstrap["stage"] == "stage2" and bootstrap["seed"] == "previous-native" do
      configuration_error!(
        :production_requires_stage2,
        "production conversion requires a previous-native Stage 2 artifact"
      )
    end
  end

  defp fetch_config!(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} ->
        value

      :error ->
        configuration_error!(
          :invalid_production_kernel_config,
          "production Ex conversion kernel config is missing #{inspect(key)}"
        )
    end
  end

  defp reject_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Ex conversion kernel provider options must be a keyword list"
    end

    keys = Keyword.keys(opts)
    missing = @required_options -- keys
    unknown = keys -- @required_options

    cond do
      missing != [] ->
        raise ArgumentError,
              "missing Ex conversion kernel provider options: #{inspect(missing)}"

      unknown != [] ->
        raise ArgumentError,
              "unknown Ex conversion kernel provider options: #{inspect(unknown)}"

      true ->
        :ok
    end
  end

  defp configuration_error!(code, message) do
    raise ConfigurationError, code: code, message: message
  end
end
