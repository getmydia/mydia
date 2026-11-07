defmodule Mydia.Downloads.Client.QBittorrent.SessionCacheTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.QBittorrent.SessionCache

  setup do
    config = %{
      host: "cache-test-#{System.unique_integer([:positive])}",
      port: 8080,
      username: "admin",
      password: "adminpass"
    }

    on_exit(fn -> SessionCache.delete(config, SessionCache.get(config)) end)
    {:ok, config: config}
  end

  # Two callers can hit a dead cookie at once. The second to finish must not
  # throw away the session the first one just logged in for.
  test "deleting a stale cookie leaves a newer one in place", %{config: config} do
    SessionCache.put(config, "SID=new")
    SessionCache.delete(config, "SID=old")

    assert SessionCache.get(config) == "SID=new"
  end

  test "deleting the cached cookie removes it", %{config: config} do
    SessionCache.put(config, "SID=old")
    SessionCache.delete(config, "SID=old")

    assert SessionCache.get(config) == nil
  end
end
