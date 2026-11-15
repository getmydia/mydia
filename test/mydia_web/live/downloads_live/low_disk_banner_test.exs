defmodule MydiaWeb.DownloadsLive.LowDiskBannerTest do
  # Not async: starts the globally named built-in Status process and sets the
  # global runtime.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Status}

  @moduletag :capture_log

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp run_built_in do
    start_supervised!({Status, name: Status})

    BuiltIn.put_runtime(%BuiltIn.Runtime{
      api_port: 3030,
      credentials: {"mydia", "x"},
      config: %Config{enabled?: true}
    })

    on_exit(&BuiltIn.clear_runtime/0)
  end

  test "shows no banner and does not crash when the built-in client is off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/downloads")
    refute has_element?(view, "#downloads-low-disk")
  end

  test "banner follows the disk status live", %{conn: conn} do
    run_built_in()
    {:ok, view, _html} = live(conn, ~p"/downloads")
    refute has_element?(view, "#downloads-low-disk")

    Status.put(:disk, {:low, %{free: "3.1 GB", reserve: "5 GB"}})
    assert has_element?(view, "#downloads-low-disk")
    assert render(element(view, "#downloads-low-disk")) =~ "3.1 GB"

    Status.put(:disk, :ok)
    refute has_element?(view, "#downloads-low-disk")
  end

  test "banner is there on first render when the disk is already low", %{conn: conn} do
    run_built_in()
    Status.put(:disk, {:low, %{free: "1 GB", reserve: "5 GB"}})
    {:ok, view, _html} = live(conn, ~p"/downloads")
    assert has_element?(view, "#downloads-low-disk")
  end
end
