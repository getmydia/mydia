defmodule Mydia.Plugins.EndpointTest do
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Endpoint
  alias Mydia.Settings

  defp install!(slug) do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{"slug" => slug, "name" => slug, "version" => "1.0.0", "capabilities" => %{}},
        granted_capabilities: %{},
        enabled: false
      })

    :ok
  end

  defp connection!(slug, base_urls) do
    {:ok, conn} =
      Connections.upsert(slug, %{
        scope: "instance",
        label: "srv",
        base_urls: base_urls,
        access_token: "t"
      })

    conn
  end

  setup do
    install!("ep")
    :ok
  end

  test "returns the cached winner without probing" do
    conn = connection!("ep", ["http://cached.test", "http://never.test"])
    {:ok, conn} = Connections.set_resolved_base_url(conn, "http://cached.test")

    assert {:ok, "http://cached.test"} =
             Endpoint.resolve(conn, probe: fn _ -> flunk("should not probe") end)
  end

  test "probes candidates and caches the first that answers" do
    conn = connection!("ep", ["http://down.test", "http://up.test"])

    probe = fn
      "http://down.test" -> {:error, :timeout}
      "http://up.test" -> :ok
    end

    assert {:ok, "http://up.test"} = Endpoint.resolve(conn, probe: probe)
    assert Repo.reload(conn).resolved_base_url == "http://up.test"
  end

  test "reports an error when no candidate answers" do
    conn = connection!("ep", ["http://a.test", "http://b.test"])

    assert {:error, %{type: :network_error}} =
             Endpoint.resolve(conn, probe: fn _ -> {:error, :timeout} end)

    assert is_nil(Repo.reload(conn).resolved_base_url)
  end

  test "reports an error when the candidate list is empty" do
    conn = connection!("ep", [])

    assert {:error, %{type: :invalid_request}} =
             Endpoint.resolve(conn, probe: fn _ -> :ok end)
  end

  test "invalidate/1 clears the cache so the next resolve re-probes" do
    conn = connection!("ep", ["http://a.test"])
    {:ok, conn} = Connections.set_resolved_base_url(conn, "http://stale.test")

    assert :ok = Endpoint.invalidate(conn)
    assert is_nil(Repo.reload(conn).resolved_base_url)
  end

  test "a cached url no longer in the candidate list is ignored" do
    conn = connection!("ep", ["http://a.test"])
    {:ok, conn} = Connections.set_resolved_base_url(conn, "http://removed.test")

    assert {:ok, "http://a.test"} = Endpoint.resolve(conn, probe: fn _ -> :ok end)
  end
end
