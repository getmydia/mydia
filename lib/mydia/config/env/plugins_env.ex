defmodule Mydia.Config.Env.PluginsEnv do
  @moduledoc """
  Reads the singular `plugins` runtime section of `Mydia.Config.Schema` from the
  environment, distinct from the PLUGIN_<N>_* settings handled by the loader.
  Only the filesystem override directory is env-configurable today
  (`PLUGINS_OVERRIDE_DIR`).
  """

  alias Mydia.Config.Loader

  @spec load() :: map()
  def load do
    %{}
    |> Loader.put_if_present(:override_dir, System.get_env("PLUGINS_OVERRIDE_DIR"))
  end
end
