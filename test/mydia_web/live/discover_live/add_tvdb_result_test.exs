defmodule MydiaWeb.DiscoverLive.AddTvdbResultTest do
  @moduledoc """
  Discover routes every TV search to TVDB (`Relay.search/3` sends `:tv_show` to
  `/tvdb/search` unless an explicit `provider: :tmdb` overrides it), so a TV
  search result carries a **TVDB series id** in `provider_id`. The card ships
  that id in a param named `tmdb_id`, and the add flow took the name at face
  value: `Mydia.Media.Add` defaults to `provider: :tmdb` and fetched the TVDB id
  from `/tmdb/tv/shows/:id`, which the relay answers with 404:

      Failed to fetch metadata: %Mydia.Metadata.Provider.Error{
        type: :not_found, message: "Media not found: 280619"}

  Reported from a production install adding a show from Discover search. The
  404 was the lucky case: when a TVDB id happens to name a real TMDB show, the
  add silently stores the wrong title's ids instead.

  The request path already branched on `item.provider`
  (`MediaRequestHelpers.build_request_attrs/3`, covered by
  `guest_request_flow_test.exs`); the add path did not. This is that test's
  twin for the Add button.
  """

  # async: false: setup_metadata_stub mutates the global Provider.Registry, and
  # connected LiveView mounts run in a separate process from the test, which the
  # non-shared Postgres sandbox hides rows from.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  setup %{conn: conn} do
    warm_genre_cache(:movie, [])
    warm_genre_cache(:tv_show, [])

    library_path_fixture(%{type: :series})

    %{conn: log_in_user(conn, create_admin_user())}
  end

  test "adding a TVDB-sourced search result stores it under tvdb_id", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&q=stub")

    assert render(view) =~ MetadataStubProvider.series_title()

    view
    |> element(
      ~s(button[phx-click="add_to_library"][phx-value-tmdb_id="#{MetadataStubProvider.series_tvdb_id()}"])
    )
    |> render_click()

    media_item = wait_until_media_item(MetadataStubProvider.series_tvdb_id())

    assert media_item.type == "tv_show"
    assert media_item.title == MetadataStubProvider.series_title()

    assert is_nil(media_item.tmdb_id),
           "a TVDB-sourced result must not be stored as a TMDB id, or the add fetches the wrong provider"
  end

  # The add lands in a handle_info the render_click round trip does not wait
  # on, matching wait_until_media_item/1 in config_modal_test.exs.
  defp wait_until_media_item(tvdb_id, retries \\ 200)

  defp wait_until_media_item(tvdb_id, 0) do
    flunk("media item for tvdb_id=#{tvdb_id} was not created in time")
  end

  defp wait_until_media_item(tvdb_id, retries) do
    case Mydia.Media.get_media_item_by_tvdb(tvdb_id) do
      nil ->
        Process.sleep(10)
        wait_until_media_item(tvdb_id, retries - 1)

      media_item ->
        media_item
    end
  end
end
