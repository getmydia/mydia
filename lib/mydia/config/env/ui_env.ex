defmodule Mydia.Config.Env.UiEnv do
  @moduledoc """
  Reads the `ui` section of `Mydia.Config.Schema` from the environment
  (`DEFAULT_UI_LANGUAGE`).
  """

  alias Mydia.Config.Loader

  @spec load() :: map()
  def load do
    %{}
    |> Loader.put_if_present(:default_locale, System.get_env("DEFAULT_UI_LANGUAGE"))
  end
end
