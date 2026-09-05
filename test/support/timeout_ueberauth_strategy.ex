defmodule MydiaWeb.TimeoutUeberauthStrategy do
  @moduledoc """
  A Ueberauth strategy whose request phase exits the way `oidcc`'s
  provider-configuration worker does when it misses the default 5s
  `GenServer.call/2` timeout while fetching a slow IdP's discovery document.

  Used to reproduce https://github.com/getmydia/mydia/issues/707 without a
  live, slow identity provider: `Ueberauth.Strategy.Oidcc.handle_request!/1`
  calls into `:gen_server.call/2` and lets a timeout's `exit/1` propagate, so
  this strategy does the same thing directly.
  """

  use Ueberauth.Strategy

  @impl Ueberauth.Strategy
  def handle_request!(_conn) do
    exit({:timeout, {:gen_server, :call, [self(), :get_provider_configuration]}})
  end
end
