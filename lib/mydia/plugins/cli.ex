defmodule Mydia.Plugins.CLI do
  @moduledoc """
  The `mydia-cli plugin` commands.

  `mydia-cli` runs these over `rpc` on the live node rather than `eval`, so the
  install lands in the running registry and its pool starts without a restart.
  Paths are resolved inside the container, so the files must be somewhere it
  can read, such as the `/config` volume.
  """

  alias Mydia.Plugins

  @usage """
  Usage: mydia-cli plugin install <plugin.wasm> <manifest.json> [--approve]

  Installs a plugin that is not in the index. Without --approve it installs
  inactive; approve its capabilities in Admin > Plugins.
  """

  @doc "Runs a `mydia-cli plugin` command. Returns `:ok` or `{:error, message}`."
  @spec run([String.t()]) :: :ok | {:error, String.t()}
  def run(["install" | args]) do
    case OptionParser.parse(args, strict: [approve: :boolean]) do
      {opts, [wasm, manifest], []} -> install(wasm, manifest, opts)
      _ -> usage()
    end
  end

  def run(_args), do: usage()

  @doc """
  Like `run/1`, but raises on failure. `bin/mydia rpc` exits 0 whatever the
  expression returns, and a raise fails the rpc client without touching the
  live node, so this is what gives `mydia-cli` a non-zero exit status.
  """
  @spec run!([String.t()]) :: :ok
  def run!(args) do
    case run(args) do
      :ok -> :ok
      {:error, message} -> raise RuntimeError, message: "mydia-cli plugin: " <> message
    end
  end

  defp install(wasm, manifest, opts) do
    case Plugins.install_file(wasm, manifest, approve: Keyword.get(opts, :approve, false)) do
      {:ok, :inactive} ->
        IO.puts("Installed inactive. Approve its capabilities in Admin > Plugins.")

      {:ok, plugin} ->
        IO.puts("Installed and activated #{plugin.slug} #{plugin.version}.")

      {:error, error} ->
        fail(error.message)
    end
  end

  defp usage do
    IO.puts(:stderr, @usage)
    {:error, "invalid arguments"}
  end

  defp fail(message) do
    IO.puts(:stderr, "Error: " <> message)
    {:error, message}
  end
end
