defmodule MydiaWeb.DashboardLive.SystemHealthTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  alias Mydia.Accounts
  alias Mydia.Settings

  setup do
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])
    :ok
  end

  test "system health is absent for non-admin even when stored in their preference", %{conn: conn} do
    user = user_fixture(%{role: "user"})
    {:ok, _} = Accounts.put_home_widgets(user, [:system_health, :library_stats])

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

    refute has_element?(view, "#system-health-widget")
  end

  test "omits tiles when no service is configured", %{conn: conn} do
    admin = user_fixture(%{role: "admin"})
    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/")

    # No clients or indexers configured in fresh test
    refute has_element?(view, "#health-tile-clients")
    refute has_element?(view, "#health-tile-indexers")
    refute has_element?(view, "#health-tile-media-servers")

    # Duplicates and trash are always shown
    assert has_element?(view, "#health-tile-duplicates")
    assert has_element?(view, "#health-tile-trash")
  end

  test "degraded rollup renders amber and links to /admin/clients", %{conn: conn} do
    admin = user_fixture(%{role: "admin"})

    if :ets.info(:download_client_health) == :undefined do
      :ets.new(:download_client_health, [:named_table, :set, :public, read_concurrency: true])
    end

    {:ok, client1} =
      Settings.create_download_client_config(%{
        name: "Client 1",
        type: :qbittorrent,
        host: "localhost",
        port: 8080,
        enabled: true,
        priority: 1
      })

    {:ok, client2} =
      Settings.create_download_client_config(%{
        name: "Client 2",
        type: :transmission,
        host: "localhost",
        port: 9091,
        enabled: true,
        priority: 2
      })

    now = System.monotonic_time(:millisecond)
    healthy_res = %{status: :healthy, checked_at: DateTime.utc_now(), details: %{}, error: nil}

    unhealthy_res = %{
      status: :unhealthy,
      checked_at: DateTime.utc_now(),
      details: %{},
      error: "Connection refused"
    }

    :ets.insert(:download_client_health, {client1.id, healthy_res, now})
    :ets.insert(:download_client_health, {client2.id, unhealthy_res, now})

    on_exit(fn ->
      if :ets.info(:download_client_health) != :undefined do
        :ets.delete(:download_client_health, client1.id)
        :ets.delete(:download_client_health, client2.id)
      end
    end)

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/")

    assert has_element?(view, ~s(#health-tile-clients[href="/admin/clients"]))
    assert has_element?(view, "#health-tile-clients .badge-warning", "1/2 healthy")
  end

  test "duplicates tile settles after async task", %{conn: conn} do
    admin = user_fixture(%{role: "admin"})
    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/")

    # Wait for async task to complete
    render_async(view)

    assert has_element?(view, "#health-tile-duplicates", "None")
  end
end
