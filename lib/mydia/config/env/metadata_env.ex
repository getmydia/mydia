defmodule Mydia.Config.Env.MetadataEnv do
  @moduledoc """
  Reads the `metadata` section of `Mydia.Config.Schema` from the environment
  (`METADATA_LANGUAGE`).
  """

  alias Mydia.Config.Loader

  @spec load() :: map()
  def load do
    %{}
    |> Loader.put_if_present(:language, System.get_env("METADATA_LANGUAGE"))
  end
end
