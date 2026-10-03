defmodule MydiaWeb.MediaLive.Show.RestrictedRecommendationsTest do
  @moduledoc """
  End-to-end proof that the media page hands the viewer's own scope to
  `Recommendations`: both the page rail and the detail dialog's rail drop what a
  restricted account may not see, and a rail with nothing left disappears
  without taking the page down.
  """

  # Connected LiveView mounts run outside the test process and
  # setup_metadata_stub swaps a global registry, so this stays sync.
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers
  import Mydia.MetadataStub

  alias Mydia.Media.RemoteSignals
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup %{conn: conn} do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    user = restricted_user_fixture(%{max_content_age: 12})
    %{conn: log_in_user(conn, user)}
  end

  # A library movie the restricted viewer is allowed to open.
  defp visible_movie(tmdb_id) do
    movie =
      media_item_fixture(%{type: "movie", title: "Quiet Harbor", year: 2021, tmdb_id: tmdb_id})

    Repo.update_all(
      from(m in Mydia.Media.MediaItem, where: m.id == ^movie.id),
      set: [content_rating_age: 8]
    )

    movie
  end

  defp warm_signals(id, content_rating, age) do
    warm_remote_signals({:tmdb, id}, :movie, %RemoteSignals{
      content_rating: content_rating,
      age: age,
      category: "movie"
    })
  end

  defp raw(id, title),
    do: %{"id" => id, "title" => title, "release_date" => "2019-04-11", "poster_path" => "/p.jpg"}

  test "the page rail keeps the allowed title and drops the blocked one", %{conn: conn} do
    source = unique_provider_id()
    allowed = unique_provider_id()
    blocked = unique_provider_id()
    warm_signals(allowed, "PG", 8)
    warm_signals(blocked, "R", 17)

    movie = visible_movie(source)

    warm_recommendations_cache(source, :movie, [
      raw(allowed, "Kind Lantern"),
      raw(blocked, "Grim Ledger")
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, "#recommendations-rail")
    assert has_element?(view, ~s(#recommendations-rail div[phx-value-id="#{allowed}"]))
    refute has_element?(view, ~s(#recommendations-rail div[phx-value-id="#{blocked}"]))
    refute render(view) =~ "Grim Ledger"
  end

  test "a rail that is entirely out of bounds is absent and the page still renders",
       %{conn: conn} do
    source = unique_provider_id()
    blocked = unique_provider_id()
    warm_signals(blocked, "R", 17)

    movie = visible_movie(source)
    warm_recommendations_cache(source, :movie, [raw(blocked, "Grim Ledger")])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    refute has_element?(view, "#recommendations-rail")
    assert render(view) =~ "Quiet Harbor"
  end

  test "the dialog's own rail is filtered for the viewer", %{conn: conn} do
    source = unique_provider_id()
    opened = unique_provider_id()
    allowed = unique_provider_id()
    blocked = unique_provider_id()
    warm_signals(opened, "PG", 8)
    warm_signals(allowed, "PG", 8)
    warm_signals(blocked, "R", 17)

    movie = visible_movie(source)
    warm_recommendations_cache(source, :movie, [raw(opened, "Salt Verge")])

    warm_recommendations_cache(opened, :movie, [
      raw(allowed, "Ninth Tide"),
      raw(blocked, "Grim Ledger")
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element(~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{opened}"]))
    |> render_click()

    render_async(view, 5000)

    assert has_element?(view, "#media-detail-modal-rail")
    assert has_element?(view, ~s(#media-detail-modal-rail [phx-value-id="#{allowed}"]))
    refute has_element?(view, ~s(#media-detail-modal-rail [phx-value-id="#{blocked}"]))
    refute render(view) =~ "Grim Ledger"
  end
end
