defmodule Mix.Tasks.Compile.CardigannGuest do
  @moduledoc """
  Makes the prebuilt Cardigann wasm guest available during a dev `mix compile`
  that opted in with `CARDIGANN_ENGINE=prowlarr`, by running
  `mix mydia.cardigann_guest fetch`. Releases download it at runtime instead
  (`Mydia.Indexers.Cardigann.Wasm.Delivery`), and CI fetches explicitly.

  Registered (appended) in `mix.exs` `compilers/0` next to `:plugins`, for the
  same reason: the task module lives in `lib/` and is only loadable after the
  `:elixir` compiler has run. It never fails the build: a missing artifact only
  means Cardigann wasm reports unavailable at runtime. A download whose checksum
  does not match is reported loudly on stderr.

  When nothing could be fetched, `priv/cardigann/.unavailable-<hash>` records the
  time and the network is not probed again for an hour, so offline work does not
  pay a timeout on every compile.

  Skipped outside the `:dev` env and when the engine is not selected. Set
  `MYDIA_SKIP_CARDIGANN_FETCH=1` to skip it even then.
  """

  use Mix.Task.Compiler

  alias Mix.Tasks.Mydia.CardigannGuest, as: Guest
  alias Mydia.Indexers.Cardigann.Wasm.Artifact

  @recursive false
  @negative_ttl_seconds 3600

  @impl Mix.Task.Compiler
  def run(_argv) do
    unless skip?(), do: fetch_and_report()
    {:noop, []}
  end

  @doc false
  def fetch_and_report do
    target = Guest.target()

    cond do
      match?({:ok, _}, Artifact.load(target)) ->
        :ok

      recently_unavailable?(target) ->
        :cached_unavailable

      true ->
        result = safe_fetch()
        report(result, target)
        result
    end
  end

  defp safe_fetch do
    {:ok, _} = Application.ensure_all_started(:req)
    Guest.fetch()
  rescue
    e -> {:unavailable, Exception.message(e)}
  end

  defp report({:error, reason}, target) do
    Mix.shell().error("""
    ERROR: the Cardigann wasm guest download failed verification (#{inspect(reason)}); nothing was
    installed at #{target}. Cardigann wasm will report unavailable at runtime.
    """)
  end

  defp report({:unavailable, _why}, target), do: File.write(marker(target), "#{now()}\n")
  defp report(:ok, _target), do: :ok

  defp recently_unavailable?(target) do
    with {:ok, body} <- File.read(marker(target)),
         {ts, _} <- Integer.parse(body) do
      now() - ts < @negative_ttl_seconds
    else
      _ -> false
    end
  end

  defp marker(target),
    do: Path.join(Path.dirname(target), ".unavailable-#{Artifact.source_hash()}")

  defp now, do: System.os_time(:second)

  # Only a dev build that opted in fetches: everyone else would pay a download
  # for an engine they never start, and releases fetch at runtime instead.
  defp skip?,
    do:
      Mix.env() != :dev or System.get_env("CARDIGANN_ENGINE") != "prowlarr" or
        System.get_env("MYDIA_SKIP_CARDIGANN_FETCH") in ["1", "true"]
end
