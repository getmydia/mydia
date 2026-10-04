defmodule Mix.Tasks.Mydia.Plugin do
  @moduledoc """
  Installs a plugin that is not in any index, for plugin development.

      mix mydia.plugin install <plugin.wasm> <manifest.json> [--approve]

  Without `--approve` the plugin installs inactive and waits for approval in
  Admin > System > Plugins. This runs in its own BEAM, not the dev server, so
  the running server only loads the install after a restart (`./dev restart`).
  Production uses `mydia-cli plugin install`, which reaches the live node.
  """
  use Mix.Task

  @shortdoc "Installs a plugin from a local .wasm and manifest"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case Mydia.Plugins.CLI.run(args) do
      :ok -> :ok
      {:error, message} -> Mix.raise("mydia.plugin: " <> message)
    end
  end
end
