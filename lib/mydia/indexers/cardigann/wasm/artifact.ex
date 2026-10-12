defmodule Mydia.Indexers.Cardigann.Wasm.Artifact do
  @moduledoc """
  The prebuilt Cardigann guest. Its name carries a hash of the tracked guest
  sources, so the source tree alone decides which artifact a build needs. CI
  builds and publishes it (`.github/workflows/cardigann-guest.yml`); everything
  else downloads it by hash (`mix mydia.cardigann_guest fetch`).
  """

  alias Mydia.Indexers.Cardigann.Wasm.SourceHash

  @root SourceHash.repo_root()

  # Releases have no git checkout and no sources, so the hash and the Prowlarr
  # tag are fixed at compile time. A change to any tracked file recompiles this
  # module.
  for f <- SourceHash.tracked_files() do
    @external_resource Path.join(@root, f)
  end

  @pinned_hash SourceHash.source_hash()

  # The SHA-256 of the published artifact, compiled into the release so a
  # runtime download can be verified without trusting the network. The pin file
  # reads "<source-hash> <sha256>"; a pin for other sources than these (stale,
  # or "unpublished") is no pin at all.
  @pin_file Path.join(@root, "native/cardigann_guest/ARTIFACT_SHA256")
  @external_resource @pin_file

  @pinned_sha256 (with {:ok, body} <- File.read(@pin_file),
                       [hash, sha] <- String.split(body),
                       true <- hash == @pinned_hash,
                       true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) do
                    sha
                  else
                    _ -> nil
                  end)

  # The precompiled component is only valid for the wasmtime that wrote it, so
  # the version is part of its file name. Read from the Wasmex crate this build
  # compiles; Wasmex pins wasmtime exactly.
  @wasmtime_cargo Path.join(Mix.Project.deps_paths()[:wasmex] || "", "native/wasmex/Cargo.toml")
  @external_resource @wasmtime_cargo
  @wasmtime_version (with {:ok, toml} <- File.read(@wasmtime_cargo),
                          [_, v] <- Regex.run(~r/^wasmtime\s*=\s*"=?([0-9.]+)"/m, toml) do
                       v
                     else
                       _ -> "unknown"
                     end)

  @default_base_url "https://github.com/getmydia/mydia/releases/download/cardigann-guest"

  @prowlarr_tag (case @root |> Path.join("native/cardigann_guest/PROWLARR_REF") |> File.read() do
                   {:ok, ref} -> ref |> String.split() |> List.first()
                   {:error, _} -> "unknown"
                 end)

  # @external_resource sees edits to known files but not a file added to the
  # guest directory; Mix calls this on every compile to catch that case. In a
  # source-less release build the hash is unchanged, so nothing recompiles.
  @doc false
  def __mix_recompile__?, do: SourceHash.source_hash() != @pinned_hash

  @doc "Tracked guest files that feed the hash, relative to the repo root."
  defdelegate tracked_files(), to: SourceHash

  @doc "16 hex characters naming the artifact this source tree needs."
  def source_hash, do: @pinned_hash

  @doc """
  Where the artifact lives (and where `fetch` puts it). The
  `:cardigann_wasm_path` application env overrides it; tests use that to point
  the engine at a missing file.
  """
  def path do
    Application.get_env(:mydia, :cardigann_wasm_path) ||
      path_in(Application.app_dir(:mydia, ["priv", "cardigann"]))
  end

  @doc "SHA-256 (hex) the published artifact must have, or nil when none is pinned for these sources."
  def pinned_sha256, do: Application.get_env(:mydia, :cardigann_pinned_sha256, @pinned_sha256)

  @doc "Where the guest is published. The `:cardigann_guest_base_url` application env overrides it."
  def base_url, do: Application.get_env(:mydia, :cardigann_guest_base_url, @default_base_url)

  @doc """
  Directory for the runtime-fetched guest and its precompiled form: under the
  data directory (`MYDIA_DATA_DIR`), so it survives upgrades when that is a
  volume. The `:cardigann_cache_dir` application env overrides it.
  """
  def cache_dir do
    Application.get_env(:mydia, :cardigann_cache_dir) ||
      Path.join(Application.get_env(:mydia, :data_dir, "priv/data"), "cardigann")
  end

  @doc "Name of the precompiled component: tied to the wasmtime version and CPU architecture."
  def cwasm_name do
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()
    "cardigann-#{@pinned_hash}-wasmtime#{@wasmtime_version}-#{arch}.cwasm"
  end

  @doc "Where the precompiled component is cached."
  def cwasm_path, do: Path.join(cache_dir(), cwasm_name())

  @doc "File name of the published release asset."
  def file_name, do: "cardigann-#{@pinned_hash}.wasm"

  @doc false
  def path_in(dir), do: Path.join(dir, file_name())

  @doc "Reads the artifact and checks it against its `.sha256` sidecar."
  @spec load(Path.t()) :: {:ok, binary()} | {:error, :missing | :checksum_mismatch}
  def load(path \\ path()) do
    with {:ok, bytes} <- read(path),
         {:ok, expected} <- read(path <> ".sha256") do
      if sha256(bytes) == String.trim(expected),
        do: {:ok, bytes},
        else: {:error, :checksum_mismatch}
    end
  end

  @doc false
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @spec version() :: %{prowlarr_tag: String.t(), hash: String.t()}
  def version, do: %{prowlarr_tag: @prowlarr_tag, hash: @pinned_hash}

  defp read(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, _} -> {:error, :missing}
    end
  end
end
