defmodule Mix.Tasks.Mydia.CardigannGuest do
  @moduledoc """
  Manages the prebuilt Cardigann wasm guest (`priv/cardigann/cardigann-<hash>.wasm`).

      mix mydia.cardigann_guest hash                  # print the source hash
      mix mydia.cardigann_guest fetch                 # download and verify
      mix mydia.cardigann_guest pin [--require]       # record the published checksum
      mix mydia.cardigann_guest verify [--allow-missing]

  `fetch` is a no-op when the file already verifies. Otherwise it downloads
  the release asset and its `.sha256`; if that fails and
  `native/cardigann_guest/out/cardigann.wasm` exists (a local `build.sh wasm`
  or a PR build) it copies that instead. With neither it warns loudly and
  exits 0, so contributors without Docker still boot, with the Cardigann wasm
  engine unavailable.

  `verify` exits non-zero when the file is missing (unless `--allow-missing`)
  or does not match its checksum.

  Test seams: `:cardigann_guest_base_url`, `:cardigann_guest_dir` and
  `:cardigann_guest_local` under the `:mydia` application env.
  """

  use Mix.Task

  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, SourceHash}

  @shortdoc "Fetches and verifies the prebuilt Cardigann wasm guest"

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [allow_missing: :boolean, require: :boolean])
    # Not app.config: that evaluates config/runtime.exs, which in a prod image
    # build raises for the deployment variables (DATABASE_PATH, SECRET_KEY_BASE)
    # a build has no value for. This task needs the code paths and the compile
    # time config only.
    Mix.Task.run("loadpaths")
    Mix.Task.run("loadconfig")
    {:ok, _} = Application.ensure_all_started(:req)

    case args do
      ["hash"] ->
        Mix.shell().info(Artifact.source_hash())

      ["fetch"] ->
        case fetch() do
          :ok -> :ok
          {:unavailable, _} -> :ok
          {:error, reason} -> Mix.raise("Cardigann guest fetch failed: #{inspect(reason)}")
        end

      ["verify"] ->
        case verify(Keyword.get(opts, :allow_missing, false)) do
          :ok -> Mix.shell().info("Cardigann guest verified: #{target()}")
          {:error, reason} -> Mix.raise("Cardigann guest #{reason}: #{target()}")
        end

      ["pin"] ->
        case pin(Keyword.get(opts, :require, false)) do
          :ok -> :ok
          {:error, reason} -> Mix.raise("Cardigann guest pin: #{reason}")
        end

      _ ->
        Mix.raise(
          "usage: mix mydia.cardigann_guest hash | fetch | pin [--require] | verify [--allow-missing]"
        )
    end
  end

  @doc """
  Makes the artifact available. Returns `:ok`, `{:unavailable, reason}` (soft,
  nothing could be found) or `{:error, :checksum_mismatch}` (a download that
  did not match its checksum; nothing is kept).
  """
  def fetch do
    target = target()

    case Artifact.load(target) do
      {:ok, _} -> :ok
      _ -> download_or_copy(target)
    end
  end

  @doc """
  Records the SHA-256 of the published guest in `<artifact>.sha256` so a release
  can verify the guest it downloads at runtime. Fetches only that sidecar from
  the release, never the 75 MB guest. Nothing to do when
  `native/cardigann_guest/ARTIFACT_SHA256` already pins this source hash. When
  no sidecar is published for it, `require?` makes that an error (release
  images); otherwise it is a warning and the engine reports "no published
  Cardigann engine for this build" at runtime.
  """
  def pin(require?) do
    name = Path.basename(target()) <> ".sha256"

    with {:pinned, nil} <- {:pinned, Artifact.compiled_pin()},
         {:ok, body} <- get(name),
         sha = String.trim(body),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) do
      File.mkdir_p!(Path.dirname(target()))
      File.write!(target() <> ".sha256", sha <> "\n")
      Mix.shell().info("Pinned Cardigann guest #{Path.basename(target())} to #{sha}")
      :ok
    else
      {:pinned, _sha} ->
        Mix.shell().info("Cardigann guest pinned by ARTIFACT_SHA256")
        :ok

      other ->
        why =
          case other do
            {:unavailable, why} -> why
            false -> "#{name} is not a SHA-256"
          end

        if require? do
          {:error, "no published checksum for #{Path.basename(target())} (#{why})"}
        else
          Mix.shell().error(
            "WARNING: no published Cardigann guest for this source (#{why}); the engine " <>
              "will report that it is unavailable for this build."
          )

          :ok
        end
    end
  end

  @doc "`:ok`, or `{:error, :missing | :checksum_mismatch}`. Missing is fine when `allow_missing?`."
  def verify(allow_missing?) do
    case Artifact.load(target()) do
      {:ok, _} ->
        :ok

      {:error, :missing} when allow_missing? ->
        Mix.shell().info("Cardigann guest not present (allowed): #{target()}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_or_copy(target) do
    File.mkdir_p!(Path.dirname(target))

    case download(target) do
      :ok -> :ok
      {:error, :checksum_mismatch} = err -> err
      {:unavailable, why} -> copy_local(target, why)
    end
  end

  defp download(target) do
    name = Path.basename(target)

    with {:ok, bytes} <- get(name),
         {:ok, sum} <- get(name <> ".sha256") do
      if Artifact.sha256(bytes) == String.trim(sum) do
        File.write!(target, bytes)
        File.write!(target <> ".sha256", String.trim(sum) <> "\n")
        Mix.shell().info("Fetched Cardigann guest #{name}")
        :ok
      else
        {:error, :checksum_mismatch}
      end
    end
  end

  defp get(name) do
    url = base_url() <> "/" <> name

    case Req.get(url, retry: false, receive_timeout: 120_000, connect_options: [timeout: 3_000]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:unavailable, "#{url} returned HTTP #{status}"}
      {:error, e} -> {:unavailable, "#{url}: #{Exception.message(e)}"}
    end
  end

  defp copy_local(target, why) do
    local = local_build()

    case File.read(local) do
      {:ok, bytes} ->
        File.write!(target, bytes)
        File.write!(target <> ".sha256", Artifact.sha256(bytes) <> "\n")
        Mix.shell().info("Cardigann guest: no published asset; using local build #{local}")
        :ok

      {:error, _} ->
        Mix.shell().error("""
        WARNING: the Cardigann wasm guest is unavailable (#{why}) and there is no
        local build at #{local}. Cardigann wasm will report unavailable at runtime.
        Build it with native/cardigann_guest/build.sh wasm (needs Docker), or wait
        for CI to publish #{Path.basename(target)}.
        """)

        {:unavailable, why}
    end
  end

  @doc false
  def target do
    case Application.get_env(:mydia, :cardigann_guest_dir) do
      nil -> Artifact.path()
      dir -> Artifact.path_in(dir)
    end
  end

  defp base_url, do: Artifact.base_url()

  defp local_build do
    Application.get_env(:mydia, :cardigann_guest_local) ||
      Path.join(SourceHash.repo_root(), "native/cardigann_guest/out/cardigann.wasm")
  end
end
