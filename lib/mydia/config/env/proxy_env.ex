defmodule Mydia.Config.Env.ProxyEnv do
  @moduledoc """
  Reads the `proxy` section of `Mydia.Config.Schema` from the environment
  (`MYDIA_PROXY_URL`, `MYDIA_PROXY_BYPASS`).
  """

  alias Mydia.Config.Loader

  @spec load((String.t() -> String.t() | nil)) :: map()
  def load(getenv \\ Mydia.Net.Proxy.getenv()) do
    %{}
    |> Loader.put_if_present(:url, getenv.("MYDIA_PROXY_URL"))
    |> Loader.put_if_present(:bypass, getenv.("MYDIA_PROXY_BYPASS"))
  end
end
