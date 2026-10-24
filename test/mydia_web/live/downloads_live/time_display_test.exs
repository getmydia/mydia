defmodule MydiaWeb.DownloadsLive.TimeDisplayTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataStub, only: [setup_metadata_stub: 1]

  alias Mydia.Accounts
  alias Mydia.TimeDisplay
  alias MydiaWeb.DateTimeFormat

  setup :setup_metadata_stub

  @instant ~U[2026-10-22 12:58:00Z]

  defp completed_download do
    item = media_item_fixture(%{title: "Fictional Salt Meridian"})

    download_fixture(%{
      media_item_id: item.id,
      imported_at: nil,
      download_client: nil,
      download_client_id: nil,
      completed_at: @instant
    })
  end

  defp tooltip(view) do
    view
    |> element("#download-detail-event-completed [data-tip]")
    |> render()
  end

  test "the drawer timeline tooltip uses the viewer's zone and clock", %{conn: conn} do
    user = admin_user_fixture()

    {:ok, _} =
      user
      |> Accounts.get_user_preference!()
      |> Accounts.update_preference(%{"time_zone" => "Europe/Rome", "clock_format" => "24"})

    download = completed_download()
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/downloads?download=#{download.id}")

    html = tooltip(view)
    assert html =~ "14:58"
    refute html =~ "UTC"
  end

  test "a user without preferences gets the instance zone on a 12-hour clock", %{conn: conn} do
    download = completed_download()

    {:ok, view, _html} =
      live(log_in_user(conn, admin_user_fixture()), ~p"/downloads?download=#{download.id}")

    display = TimeDisplay.resolve(nil, TimeDisplay.instance_time_zone(), "en")
    expected = DateTimeFormat.format(@instant, :datetime, display)

    html = tooltip(view)
    assert html =~ expected
    refute html =~ "UTC"
  end
end
