defmodule MydiaWeb.DownloadsLive.AdoptedBadgeTest do
  @moduledoc """
  The badge must survive a database round trip.

  `Mydia.Settings.JsonMapType.cast/1` passes a map through unchanged, so a
  struct built in memory carries atom keys while the same row loaded back
  carries string keys after JSON decoding. A badge written against atom keys
  works immediately after adoption and stops working after the next page load,
  which is the worst possible failure for a feature whose entire purpose is to
  be visible.

  These downloads are inserted and then re-read through the LiveView, so the
  string-key path is the one under test.
  """
  # Not async: a connected LiveView mount runs in a separate process from the
  # test. Under PostgreSQL with async: true the sandbox is non-shared, so that
  # process cannot see the rows this test inserts and the list renders empty.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "renders the badge for a download adopted from the client", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune: Part Two"})

    download_fixture(%{
      title: "Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP",
      media_item_id: media_item.id,
      download_client: "qbit",
      metadata: %{matched_from_client: true}
    })

    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(view, "[data-test=adopted-badge]")
  end

  test "does not render the badge for a download Mydia grabbed itself", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Some Other Film"})

    download_fixture(%{
      title: "Some.Other.Film.2024.1080p.WEB-DL.x264-OTHER",
      media_item_id: media_item.id,
      download_client: "qbit",
      metadata: %{size: 1000}
    })

    {:ok, view, _html} = live(conn, ~p"/downloads")

    refute has_element?(view, "[data-test=adopted-badge]")
  end
end
