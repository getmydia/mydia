defmodule Mydia.Test.ProxyEnv do
  @moduledoc """
  The test environment's `:proxy_getenv` (see `Mydia.Net.Proxy.getenv/0`):
  `System.get_env/1` with the proxy variables hidden, so a developer's shell
  proxy never reaches the suite.
  """

  @hidden ~w(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy
             MYDIA_PROXY_URL MYDIA_PROXY_BYPASS)

  @spec getenv(String.t()) :: String.t() | nil
  def getenv(name) when name in @hidden, do: nil
  def getenv(name), do: System.get_env(name)
end
