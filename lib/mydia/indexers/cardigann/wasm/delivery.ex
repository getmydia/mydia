defmodule Mydia.Indexers.Cardigann.Wasm.Delivery do
  @moduledoc """
  Gets the Cardigann guest onto disk at runtime, for installs that opted into
  `CARDIGANN_ENGINE=prowlarr`. The release image carries no guest.

  `ensure/0` resolves the `.wasm` in this order:

    1. `CARDIGANN_WASM_PATH`, for air-gapped installs. Verified against the
       SHA-256 compiled into the release, like a download.
    2. The development artifact (`priv/cardigann/`, put there by
       `mix mydia.cardigann_guest fetch` or a local build) and its sidecar.
    3. `<data dir>/cardigann/cardigann-<hash>.wasm`, when it still matches the pin.
    4. A download from the pinned GitHub release into that directory: verified,
       then written atomically. A checksum mismatch is an error. It never falls
       back to an unverified file.

  Every step but the development artifact needs the pin (`Artifact.pinned_sha256/0`);
  a build without one cannot verify anything and says so.

  `prune/1` removes what earlier versions left in the directory.
  """

  require Logger

  alias Mydia.Indexers.Cardigann.Wasm.Artifact

  @type reason ::
          :no_pin
          | {:env_path_unreadable, Path.t()}
          | {:checksum_mismatch, String.t()}
          | {:download_failed, String.t()}
          | {:write_failed, term()}

  @doc "The verified `.wasm` path, downloading it first when nothing usable is on disk."
  @spec ensure() :: {:ok, Path.t()} | {:error, reason()}
  def ensure do
    case env_path() do
      nil -> ensure_local_or_cached()
      path -> from_env(path)
    end
  end

  defp env_path do
    case System.get_env("CARDIGANN_WASM_PATH") do
      v when v in [nil, ""] -> nil
      path -> path
    end
  end

  defp from_env(path) do
    with {:ok, pin} <- pin(),
         {:ok, bytes} <- or_error(File.read(path), {:env_path_unreadable, path}),
         :ok <- verify(bytes, pin, "CARDIGANN_WASM_PATH #{path}") do
      {:ok, path}
    end
  end

  defp ensure_local_or_cached do
    case Artifact.load() do
      {:ok, _bytes} -> {:ok, Artifact.path()}
      {:error, _} -> ensure_cached()
    end
  end

  defp ensure_cached do
    target = Path.join(Artifact.cache_dir(), Artifact.file_name())

    with {:ok, pin} <- pin() do
      if cached?(target, pin), do: {:ok, target}, else: download(target, pin)
    end
  end

  defp cached?(target, pin) do
    case File.read(target) do
      {:ok, bytes} ->
        if Artifact.sha256(bytes) == pin do
          true
        else
          Logger.warning("Cardigann engine: #{target} does not match its pin, fetching again")
          File.rm(target)
          false
        end

      {:error, _} ->
        false
    end
  end

  defp download(target, pin) do
    url = Artifact.base_url() <> "/" <> Artifact.file_name()
    Logger.info("Cardigann engine: downloading #{url}")

    with {:ok, bytes} <- get(url),
         :ok <- verify(bytes, pin, url),
         :ok <- write_atomically(target, bytes) do
      {:ok, target}
    end
  end

  defp get(url) do
    case Req.get(url,
           retry: false,
           decode_body: false,
           receive_timeout: 300_000,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:download_failed, "#{url} returned HTTP #{status}"}}

      {:error, e} ->
        {:error, {:download_failed, "#{url}: #{Exception.message(e)}"}}
    end
  end

  defp verify(bytes, pin, source) do
    if Artifact.sha256(bytes) == pin, do: :ok, else: {:error, {:checksum_mismatch, source}}
  end

  @doc """
  Writes `bytes` to a sibling temp file and renames it into place, so a crash
  never leaves a truncated file under the final name.
  """
  @spec write_atomically(Path.t(), binary()) :: :ok | {:error, {:write_failed, term()}}
  def write_atomically(target, bytes) do
    tmp = "#{target}.part-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write_failed, reason}}
    end
  end

  defp pin do
    case Artifact.pinned_sha256() do
      nil -> {:error, :no_pin}
      sha -> {:ok, sha}
    end
  end

  defp or_error({:ok, _} = ok, _reason), do: ok
  defp or_error({:error, _}, reason), do: {:error, reason}

  @doc """
  Deletes the guest files other versions left in the cache directory: anything
  named `cardigann-*` that is not the current `.wasm` or `.cwasm`. Run it after
  a successful load; failures are ignored.
  """
  @spec prune(Path.t()) :: [Path.t()]
  def prune(dir \\ Artifact.cache_dir()) do
    keep = [Artifact.file_name(), Artifact.cwasm_name()]

    removed =
      dir
      |> Path.join("cardigann-*")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in keep))
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&(File.rm(&1) == :ok))

    if removed != [],
      do: Logger.info("Cardigann engine: removed #{length(removed)} stale file(s)")

    removed
  end

  @doc "A printable reason."
  @spec describe(reason()) :: String.t()
  def describe(:no_pin),
    do:
      "this build has no pinned checksum for the engine, so it cannot be downloaded or verified " <>
        "(native/cardigann_guest/ARTIFACT_SHA256)"

  def describe({:env_path_unreadable, path}), do: "CARDIGANN_WASM_PATH #{path} cannot be read"

  def describe({:checksum_mismatch, source}),
    do: "#{source} does not match the checksum pinned in this build"

  def describe({:download_failed, why}), do: "the engine download failed: #{why}"
  def describe({:write_failed, why}), do: "the engine could not be saved: #{inspect(why)}"
end
