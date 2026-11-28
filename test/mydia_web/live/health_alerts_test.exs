defmodule MydiaWeb.HealthAlertsTest do
  # async: false: alerts broadcast on the one global "health:alerts" topic, so
  # concurrent tests would see each other's banners.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  alias Mydia.Health.Alert
  alias Mydia.Health.Alerts
  alias MydiaWeb.HealthAlertText

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 3600, :second)

  defp vpn_alert do
    %Alert{
      key: :built_in_blocked,
      title: "x",
      detail: "The VPN tunnel is down.",
      since: hours_ago(3),
      fix_path: "/admin/clients"
    }
  end

  defp root_alert do
    %Alert{
      key: {:library_root_missing, "lp1"},
      title: "x",
      detail: "/srv/films does not exist or is not a folder.",
      since: hours_ago(1),
      fix_path: "/admin/library-paths"
    }
  end

  defp broadcast(alerts) do
    Phoenix.PubSub.broadcast(Mydia.PubSub, Alerts.topic(), {:health_alerts, alerts})
  end

  setup do
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])
    :ok
  end

  describe "sidebar banner" do
    setup %{conn: conn}, do: %{conn: log_in_user(conn, admin_user_fixture())}

    test "admin sees the sidebar banner after a broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#sidebar-health-alert")

      broadcast([vpn_alert()])

      assert has_element?(view, "#sidebar-health-alert a[href='/admin/clients']")
      assert view |> element("#sidebar-health-alert") |> render() =~ "for 3h"
    end

    test "several alerts link home with a count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      broadcast([vpn_alert(), root_alert()])

      assert has_element?(view, "#sidebar-health-alert a[href='/']")
      assert view |> element("#sidebar-health-alert") |> render() =~ "2"
    end

    test "an empty broadcast removes the banner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      broadcast([vpn_alert()])
      assert has_element?(view, "#sidebar-health-alert")

      broadcast([])
      refute has_element?(view, "#sidebar-health-alert")
    end
  end

  describe "home card" do
    setup %{conn: conn}, do: %{conn: log_in_user(conn, admin_user_fixture())}

    test "admin home shows every alert with its detail and fix link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      broadcast([vpn_alert(), root_alert()])

      assert has_element?(view, "#home-health-alerts")
      assert view |> element("#home-health-alert-0") |> render() =~ "The VPN tunnel is down."
      assert has_element?(view, "#home-health-alert-0 a[href='/admin/clients']")
      assert has_element?(view, "#home-health-alert-1 a[href='/admin/library-paths']")
    end

    test "home card hidden without alerts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#home-health-alerts")
    end
  end

  test "non-admin home shows no card", %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{role: "user"}))
    {:ok, view, _html} = live(conn, ~p"/")

    broadcast([vpn_alert()])

    refute has_element?(view, "#home-health-alerts")
  end

  test "non-admin never sees the sidebar banner", %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{role: "user"}))
    {:ok, view, _html} = live(conn, ~p"/")

    broadcast([vpn_alert()])

    refute has_element?(view, "#sidebar-health-alert")
  end

  describe "HealthAlertText.duration/2" do
    setup do: %{now: ~U[2026-01-03 01:00:00Z]}

    defp since(now, seconds),
      do: %Alert{key: :k, title: "t", fix_path: "/", since: DateTime.add(now, -seconds, :second)}

    test "rounds up to at least a minute", %{now: now} do
      assert HealthAlertText.duration(since(now, 59), now) == "for 1m"
    end

    test "minutes, hours, days", %{now: now} do
      assert HealthAlertText.duration(since(now, 12 * 60), now) == "for 12m"
      assert HealthAlertText.duration(since(now, 3 * 3600), now) == "for 3h"
      assert HealthAlertText.duration(since(now, 49 * 3600), now) == "for 2d"
    end
  end

  test "HealthAlertText.title/1 translates by key and falls back to the alert title" do
    assert HealthAlertText.title(vpn_alert()) ==
             "Downloads stopped: the built-in client is blocked"

    assert HealthAlertText.title(root_alert()) == "A library folder is missing"

    assert HealthAlertText.title(%Alert{
             key: :new_kind,
             title: "Raw",
             fix_path: "/",
             since: hours_ago(1)
           }) == "Raw"
  end
end
