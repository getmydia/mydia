defmodule Mix.Tasks.Compile.CardigannGuest do
  @moduledoc """
  Makes the prebuilt Cardigann wasm guest available during `mix compile`
  (dev, CI, the Docker image build), by running `mix mydia.cardigann_guest fetch`.

  Registered (appended) in `mix.exs` `compilers/0` next to `:plugins`, for the
  same reason: the task module lives in `lib/` and is only loadable after the
  `:elixir` compiler has run. It never fails the build. A missing artifact only
  means Cardigann wasm reports unavailable at runtime; the Docker build adds a
  `verify` step that does fail on a present-but-corrupt file.

  Skipped in the `:test` env, where a network probe on every `mix test` would be
  noise; CI fetches explicitly. Set `MYDIA_SKIP_CARDIGANN_FETCH=1` to skip it
  elsewhere (the Nix build does, because it places a hash-pinned copy itself).
  """

  use Mix.Task.Compiler

  @recursive false

  @impl Mix.Task.Compiler
  def run(_argv) do
    if skip?() do
      {:noop, []}
    else
      try do
        {:ok, _} = Application.ensure_all_started(:req)
        Mix.Tasks.Mydia.CardigannGuest.fetch()
      rescue
        e ->
          Mix.shell().error("Cardigann guest fetch skipped: #{Exception.message(e)}")
      end

      {:noop, []}
    end
  end

  defp skip?,
    do: Mix.env() == :test or System.get_env("MYDIA_SKIP_CARDIGANN_FETCH") in ["1", "true"]
end
