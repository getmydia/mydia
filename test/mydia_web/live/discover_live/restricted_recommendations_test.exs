defmodule MydiaWeb.DiscoverLive.RestrictedRecommendationsTest do
  @moduledoc """
  End-to-end proof that the Discover modal hands the viewer's own scope to
  `Recommendations`: a restricted account's rail keeps what it may see and
  drops the rest.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubs
  import Phoenix.LiveViewTest

  alias Mydia.Media.RemoteSignals

  setup %{conn: conn} do
    warm_genre_cache(:movie, [])

    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    user = restricted_user_fixture(%{max_content_age: 12})
    %{conn: log_in_user(conn, user), bypass: bypass}
  end

  defp wait_until(fun, retries \\ 200)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, retries) do
    fun.() || (Process.sleep(10) && wait_until(fun, retries - 1))
  end

  defp signals(id, content_rating, age) do
    warm_remote_signals({:tmdb, id}, :movie, %RemoteSignals{
      content_rating: content_rating,
      age: age,
      category: "movie"
    })
  end

  defp open_modal(conn, bypass, card_id) do
    signals(card_id, "PG", 8)
    stub_tmdb_movie(bypass, card_id, title: "Open Card", certification: "PG")
    warm_trending_cache(:movie, [%{"id" => card_id, "title" => "Open Card"}])

    {:ok, view, _html} = live(conn, ~p"/discover")

    view
    |> element("div[phx-click='show_details'][phx-value-id='#{card_id}']")
    |> render_click()

    view
  end

  test "the modal rail keeps the allowed title and drops the blocked one", %{
    conn: conn,
    bypass: bypass
  } do
    card = unique_provider_id()
    allowed = unique_provider_id()
    blocked = unique_provider_id()
    signals(allowed, "PG", 8)
    signals(blocked, "R", 17)

    warm_recommendations_cache(card, :movie, [
      %{"id" => allowed, "title" => "Kind Lantern", "release_date" => "2020-01-01"},
      %{"id" => blocked, "title" => "Grim Ledger", "release_date" => "2020-01-01"}
    ])

    view = open_modal(conn, bypass, card)

    assert wait_until(fn ->
             has_element?(view, "#discover-recommendations-rail-item-#{allowed}")
           end)

    refute has_element?(view, "#discover-recommendations-rail-item-#{blocked}")
    refute render(view) =~ "Grim Ledger"
  end

  test "an entirely out-of-bounds rail is absent and the modal stays up", %{
    conn: conn,
    bypass: bypass
  } do
    card = unique_provider_id()
    blocked = unique_provider_id()
    signals(blocked, "R", 17)

    warm_recommendations_cache(card, :movie, [
      %{"id" => blocked, "title" => "Grim Ledger", "release_date" => "2020-01-01"}
    ])

    view = open_modal(conn, bypass, card)

    assert has_element?(view, "#discover-detail-modal[open]")
    # The lookup is async; let it land before asserting absence.
    Process.sleep(300)
    render(view)

    refute has_element?(view, "#discover-recommendations-rail")
    refute render(view) =~ "Grim Ledger"
    assert has_element?(view, "#discover-detail-modal[open]")
  end
end
