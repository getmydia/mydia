defmodule Mix.Tasks.Compile.CardigannGuest do
  @moduledoc """
  Makes the prebuilt Cardigann wasm guest available during `mix compile`
  (dev, CI, the Docker image build), by running `mix mydia.cardigann_guest fetch`.

  Registered (appended) in `mix.exs` `compilers/0` next to `:plugins`, for the
  same reason: the task module lives in `lib/` and is only loadable after the
  `:elixir` compiler has run. It never fails the build: a missing artifact only
  means Cardigann wasm reports unavailable at runtime. A download whose checksum
  does not match is reported loudly on stderr. The Docker build runs the `fetch`
  and `verify` tasks explicitly afterwards, which do fail on a corrupt file.

  When nothing could be fetched, `priv/cardigann/.unavailable-<hash>` records the
  time and the network is not probed again for an hour, so offline work does not
  pay a timeout on every compile.

  Skipped in the `:test` env, where a network probe on every `mix test` would be
  noise; CI fetches explicitly. Set `MYDIA_SKIP_CARDIGANN_FETCH=1` to skip it
  elsewhere (the Nix build does, because it places a hash-pinned copy itself).
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

  defp skip?,
    do: Mix.env() == :test or System.get_env("MYDIA_SKIP_CARDIGANN_FETCH") in ["1", "true"]
end
