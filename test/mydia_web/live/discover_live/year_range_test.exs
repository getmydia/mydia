defmodule MydiaWeb.DiscoverLive.YearRangeTest do
  @moduledoc """
  The custom filter's From/To years reach TMDB discover as release-date
  bounds. Driven through handle_info(:load_data, ...) on a hand-built socket,
  with the relay stubbed by Bypass, the same seam RemoteFilterWiringTest uses.
  """

  use Mydia.DataCase, async: false

  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias MydiaWeb.DiscoverLive.Index

  # Clears the shared ETS metadata cache before and after every test, so each
  # test's Metadata.discover/2 cache key starts empty and expect_once is not
  # defeated by a cached response from an earlier test.
  setup :setup_metadata_stub

  # Metadata.discover/2 bypasses the provider registry and talks to the
  # configured relay URL directly, so point it at a local Bypass.
  setup do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    %{bypass: bypass}
  end

  defp stub_socket(assigns) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      library_status_map: %{},
      request_status_map: %{},
      selected_recommendations: [],
      selected_item: nil,
      hide_owned: false,
      visible_items: [],
      loading_more: false,
      items: [],
      page: 1,
      total_pages: 1,
      has_more: false,
      load_error: nil,
      loading: true,
      home_country: nil
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(defaults, assigns)}
  end

  defp load_with(bypass, year_from, year_to) do
    test_pid = self()

    Bypass.expect_once(bypass, "GET", "/tmdb/movies/discover", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:discover_params, conn.query_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)

    socket =
      stub_socket(%{
        media_type: :movie,
        search_mode: false,
        search_query: "",
        category: :discover,
        selected_genres: [],
        selected_language: nil,
        year_from: year_from,
        year_to: year_to,
        min_rating: nil,
        sort_by: "popularity.desc",
        current_scope: Scope.unrestricted()
      })

    Index.handle_info(:load_data, socket)
    assert_receive {:discover_params, params}
    params
  end

  test "a closed range sends both bounds", %{bypass: bypass} do
    params = load_with(bypass, 1990, 2000)

    assert params["primary_release_date.gte"] == "1990-01-01"
    assert params["primary_release_date.lte"] == "2000-12-31"
    refute Map.has_key?(params, "year")
  end

  test "an open end sends one bound", %{bypass: bypass} do
    params = load_with(bypass, 1985, nil)

    assert params["primary_release_date.gte"] == "1985-01-01"
    refute Map.has_key?(params, "primary_release_date.lte")
  end
end
