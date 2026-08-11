defmodule Mydia.WatchSync do
  @moduledoc """
  Provider-generic bi-directional watch state sync.

  Replaces the Plex-only `Mydia.MediaServer.WatchedSync` engine. Providers
  implement `Mydia.WatchSync.Provider`; the merge lives in
  `Mydia.WatchSync.Reconciler` and the I/O in `Mydia.WatchSync.Engine`.
  """

  defdelegate sync(provider_mod, instance, user_scope, opts), to: Mydia.WatchSync.Engine
end
