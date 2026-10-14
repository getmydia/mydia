defmodule Mydia.Indexers.Cardigann.Wasm.Delivery do
  @moduledoc """
  Gets the Cardigann guest onto disk at runtime, for installs that opted into
  `CARDIGANN_ENGINE=prowlarr`. The release image carries no guest.

  `ensure/1` resolves the `.wasm` and returns its path with the bytes that were
  verified. Callers compile those bytes and do not read the path again, so a
  file swapped in after the check is never used. The order:

    1. `CARDIGANN_WASM_PATH`, for air-gapped installs. Verified against the
       SHA-256 compiled into the release, like a download.
    2. The development artifact (`priv/cardigann/`, put there by
       `mix mydia.cardigann_guest fetch` or a local build) and its sidecar.
       Skipped in a release, which has no Mix.
    3. `<data dir>/cardigann/cardigann-<hash>.wasm`, when it still matches the pin.
    4. A download from the pinned GitHub release into that directory: verified,
       then written atomically. A checksum mismatch is an error. It never falls
       back to an unverified file.

  Every step but the development artifact needs the pin (`Artifact.pinned_sha256/0`);
  a build without one cannot verify anything and says so.

  `fetch_precompiled/2` gets the CI-built `.cwasm` for this architecture, when
  the build carries its pin (`Artifact.cwasm_pin/0`).

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

  @progress_interval_ms 250

  @doc """
  The verified `.wasm` path and bytes, downloading it first when nothing usable
  is on disk. `progress: fun(bytes, total)` is called during a download (at most
  every #{@progress_interval_ms} ms, and once at the end); `total` is `nil` when
  the server sends no content length.
  """
  @spec ensure(keyword()) :: {:ok, Path.t(), binary()} | {:error, reason()}
  def ensure(opts \\ []) do
    case env_path() do
      nil -> ensure_local_or_cached(opts)
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
      {:ok, path, bytes}
    end
  end

  defp ensure_local_or_cached(opts) do
    # The development artifact trusts its own sidecar, so a release (no Mix)
    # does not take this branch: there only the pin counts.
    with true <- Code.ensure_loaded?(Mix),
         {:ok, bytes} <- Artifact.load() do
      {:ok, Artifact.path(), bytes}
    else
      _ -> ensure_cached(opts)
    end
  end

  defp ensure_cached(opts) do
    target = Path.join(Artifact.cache_dir(), Artifact.file_name())

    with {:ok, pin} <- pin() do
      case cached(target, pin) do
        {:ok, bytes} -> {:ok, target, bytes}
        :miss -> download(target, pin, opts)
      end
    end
  end

  defp cached(target, pin) do
    with {:ok, bytes} <- File.read(target) do
      if Artifact.sha256(bytes) == pin do
        {:ok, bytes}
      else
        Logger.warning("Cardigann engine: #{target} does not match its pin, fetching again")
        File.rm(target)
        :miss
      end
    else
      {:error, _} -> :miss
    end
  end

  defp download(target, pin, opts) do
    url = Artifact.base_url() <> "/" <> Artifact.file_name()
    Logger.info("Cardigann engine: downloading #{url}")

    with {:ok, bytes} <- get(url, Keyword.get(opts, :progress, fn _, _ -> :ok end)),
         :ok <- verify(bytes, pin, url),
         :ok <- write_atomically(target, bytes) do
      {:ok, target, bytes}
    end
  end

  # The body is collected in the response's private map so progress can be
  # reported per chunk. The 39 MB guest is compiled from memory anyway.
  defp get(url, progress) do
    case Req.get(url,
           retry: false,
           decode_body: false,
           receive_timeout: 300_000,
           connect_options: [timeout: 10_000],
           into: &collect(&1, &2, progress)
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        bytes =
          resp
          |> Req.Response.get_private(:chunks, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        progress.(byte_size(bytes), content_length(resp))
        {:ok, bytes}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:download_failed, "#{url} returned HTTP #{status}"}}

      {:error, e} ->
        {:error, {:download_failed, "#{url}: #{Exception.message(e)}"}}
    end
  end

  defp collect({:data, data}, {req, %Req.Response{status: 200} = resp}, progress) do
    chunks = [data | Req.Response.get_private(resp, :chunks, [])]
    received = Req.Response.get_private(resp, :received, 0) + byte_size(data)

    resp =
      resp
      |> Req.Response.put_private(:chunks, chunks)
      |> Req.Response.put_private(:received, received)
      |> report_progress(received, progress)

    {:cont, {req, resp}}
  end

  # An error page is not the guest: drop it, the status decides.
  defp collect({:data, _data}, acc, _progress), do: {:cont, acc}

  # Calls `progress` at most every @progress_interval_ms, tracking the last
  # report in the response's private map.
  defp report_progress(resp, received, progress) do
    now = System.monotonic_time(:millisecond)
    last = Req.Response.get_private(resp, :reported_at, nil)

    if last == nil or now - last >= @progress_interval_ms do
      progress.(received, content_length(resp))
      Req.Response.put_private(resp, :reported_at, now)
    else
      resp
    end
  end

  defp content_length(resp) do
    with [value | _] <- Req.Response.get_header(resp, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end

  @doc """
  Downloads the CI-built `.cwasm.gz` for this architecture into `target`,
  inflating it on the fly so the 119 MB file never sits in memory, and keeps it
  only when its SHA-256 matches `Artifact.cwasm_pin/0`. Writes the
  `<target>.sha256` sidecar that `Engine` checks before every load. `:no_pin`
  when the build has no pin (Nix, a source build, an image built before the
  asset was published): the caller compiles locally.

  `progress: fun(bytes, total)` is called as in `ensure/1`, with compressed
  byte counts.
  """
  @spec fetch_precompiled(Path.t(), keyword()) :: :ok | :no_pin | {:error, reason()}
  def fetch_precompiled(target, opts \\ []) do
    case Artifact.cwasm_pin() do
      nil -> :no_pin
      pin -> fetch_precompiled(target, pin, Keyword.get(opts, :progress, fn _, _ -> :ok end))
    end
  end

  defp fetch_precompiled(target, pin, progress) do
    url = Artifact.cwasm_base_url() <> "/" <> Artifact.cwasm_asset_name()
    tmp = "#{target}.part-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
    Logger.info("Cardigann engine: downloading #{url}")

    try do
      with :ok <- ensure_dir(Path.dirname(target)),
           {:ok, sha} <- stream_gunzip(url, tmp, progress),
           :ok <- if(sha == pin, do: :ok, else: {:error, {:checksum_mismatch, url}}),
           :ok <- write_atomically(target <> ".sha256", sha <> "\n"),
           :ok <- or_write_failed(File.rename(tmp, target)) do
        :ok
      else
        error ->
          discard_partial(tmp, target)
          error
      end
    catch
      kind, reason ->
        discard_partial(tmp, target)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp discard_partial(tmp, target) do
    File.rm(tmp)
    File.rm(target <> ".sha256")
  end

  defp or_write_failed(:ok), do: :ok
  defp or_write_failed({:error, reason}), do: {:error, {:write_failed, reason}}

  # Inflates each chunk into a 0600 file and hashes what was written. Req runs
  # the `into:` function in this process, so the raw file handle opened here is
  # usable from it. The inflate state lives in the response's private map.
  defp stream_gunzip(url, tmp, progress) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)

      with :ok <- File.write(tmp, ""),
           :ok <- File.chmod(tmp, 0o600),
           {:ok, io} <- File.open(tmp, [:write, :binary, :raw]) do
        try do
          state = %{io: io, z: z, hash: :crypto.hash_init(:sha256), progress: progress}
          request_gunzip(url, state)
        after
          File.close(io)
        end
      else
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    after
      :zlib.close(z)
    end
  end

  defp request_gunzip(url, state) do
    case Req.get(url,
           retry: false,
           decode_body: false,
           receive_timeout: 300_000,
           connect_options: [timeout: 10_000],
           into: &inflate_chunk(&1, &2, state)
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        case Req.Response.get_private(resp, :cwasm) do
          {:error, {:write_failed, _} = reason} -> {:error, reason}
          {:error, why} -> {:error, {:download_failed, "#{url}: #{why}"}}
          nil -> {:error, {:download_failed, "#{url}: empty body"}}
          %{hash: hash} -> {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:download_failed, "#{url} returned HTTP #{status}"}}

      {:error, e} ->
        {:error, {:download_failed, "#{url}: #{Exception.message(e)}"}}
    end
  end

  defp inflate_chunk({:data, data}, {req, %Req.Response{status: 200} = resp}, initial) do
    case Req.Response.get_private(resp, :cwasm, initial) do
      {:error, _} ->
        {:halt, {req, resp}}

      state ->
        try do
          out = :zlib.inflate(state.z, data)

          case :file.write(state.io, out) do
            :ok ->
              received = Req.Response.get_private(resp, :received, 0) + byte_size(data)
              state = %{state | hash: :crypto.hash_update(state.hash, out)}

              resp =
                resp
                |> Req.Response.put_private(:cwasm, state)
                |> Req.Response.put_private(:received, received)
                |> report_progress(received, state.progress)

              {:cont, {req, resp}}

            {:error, reason} ->
              {:halt,
               {req, Req.Response.put_private(resp, :cwasm, {:error, {:write_failed, reason}})}}
          end
        rescue
          e in ErlangError ->
            why = "not gzip (#{inspect(e.original)})"
            {:halt, {req, Req.Response.put_private(resp, :cwasm, {:error, why})}}
        end
    end
  end

  # An error page is not the guest: drop it, the status decides.
  defp inflate_chunk({:data, _}, acc, _initial), do: {:cont, acc}

  defp verify(bytes, pin, source) do
    if Artifact.sha256(bytes) == pin, do: :ok, else: {:error, {:checksum_mismatch, source}}
  end

  @doc """
  Creates the cache directory, readable by the app user only (0700).

  Trust model: anyone who can write the data directory can already replace the
  database and the app's config, so this guards against corruption, stale files
  and other local users, not against that writer.
  """
  @spec ensure_dir(Path.t()) :: :ok | {:error, term()}
  def ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  @doc """
  Writes `bytes` to a sibling temp file (0600) and renames it into place, so a
  crash never leaves a truncated file under the final name.
  """
  @spec write_atomically(Path.t(), binary()) :: :ok | {:error, {:write_failed, term()}}
  def write_atomically(target, bytes) do
    tmp = "#{target}.part-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"

    with :ok <- ensure_dir(Path.dirname(target)),
         :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
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

  @stale_part_seconds 3600

  @doc """
  Deletes the guest files other versions left in the cache directory: anything
  named `cardigann-*` that is not the current `.wasm`, the `.cwasm` for
  `wasm_sha256` and its checksum file. A `.part-` temp file is left alone for an
  hour, in case another process is still writing it. Failures are ignored.
  """
  @spec prune(Path.t(), String.t()) :: [Path.t()]
  def prune(dir, wasm_sha256) do
    cwasm = Artifact.cwasm_name(wasm_sha256)
    keep = [Artifact.file_name(), cwasm, cwasm <> ".sha256"]
    now = System.os_time(:second)

    removed =
      dir
      |> Path.join("cardigann-*")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in keep))
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&fresh_part?(&1, now))
      |> Enum.filter(&(File.rm(&1) == :ok))

    if removed != [],
      do: Logger.info("Cardigann engine: removed #{length(removed)} stale file(s)")

    removed
  end

  defp fresh_part?(path, now) do
    String.contains?(path, ".part-") and
      match?(
        {:ok, %{mtime: m}} when now - m < @stale_part_seconds,
        File.stat(path, time: :posix)
      )
  end

  @doc "A printable reason."
  @spec describe(reason()) :: String.t()
  def describe(:no_pin), do: "no published Cardigann engine for this build"

  def describe({:env_path_unreadable, path}), do: "CARDIGANN_WASM_PATH #{path} cannot be read"

  def describe({:checksum_mismatch, source}),
    do: "#{source} does not match the checksum pinned in this build"

  def describe({:download_failed, why}), do: "the engine download failed: #{why}"
  def describe({:write_failed, why}), do: "the engine could not be saved: #{inspect(why)}"
end
