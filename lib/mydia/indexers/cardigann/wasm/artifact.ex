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

  @doc "Where the artifact lives (and where `fetch` puts it)."
  def path, do: path_in(Application.app_dir(:mydia, ["priv", "cardigann"]))

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
