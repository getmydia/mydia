defmodule MydiaWeb.DiscoverLive.RemoteFilterWiringTest do
  @moduledoc """
  Proves each of RemoteFilter's call sites inside DiscoverLive.Index is
  actually wired to the caller's scope, not just that RemoteFilter.allow?/2
  itself works in isolation (see restricted_discover_test.exs for those unit
  tests). If any of these three call sites lost its
  `RemoteFilter.filter(..., socket.assigns.current_scope)` pipe, or passed the
  wrong scope, one of these tests would fail.

  Built with hand-constructed sockets and `handle_info/2`/`handle_async/3`
  called directly, the same seam FranchiseEventsTest and
  AddToLibraryGuardTest use, so none of this needs a connected mount.
  """

  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.MetadataStubProvider
  alias MydiaWeb.DiscoverLive.Index

  # Registers MetadataStubProvider for :metadata_relay (used by the search
  # describe block below, which goes through Metadata.search_cached/3 and the
  # provider registry) and clears the shared ETS metadata cache before and
  # after every test in this file, which is what keeps the discover/curated
  # describe block's unique cache key guarantee airtight even though it never
  # touches the registry.
  setup :setup_metadata_stub

  defp stub_socket(assigns) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      library_status_map: %{},
      request_status_map: %{},
      selected_recommendations: [],
      items: [],
      page: 1,
      total_pages: 1,
      has_more: false,
      load_error: nil,
      loading: true
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(defaults, assigns)}
  end

  defp recommendation,
    do: %SearchResult{provider_id: "99", provider: :metadata_relay, media_type: :movie}

  describe "search results (handle_info(:load_data, ...), search_mode: true)" do
    test "a category-restricted scope drops an out-of-bounds search hit" do
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      socket =
        stub_socket(%{
          media_type: :movie,
          search_mode: true,
          search_query: "stub",
          category: :trending,
          current_scope: scope
        })

      {:noreply, updated} = Index.handle_info(:load_data, socket)

      refute Enum.any?(updated.assigns.items, &(&1.title == MetadataStubProvider.movie_title()))
    end

    test "an unrestricted scope keeps the same hit" do
      socket =
        stub_socket(%{
          media_type: :movie,
          search_mode: true,
          search_query: "stub",
          category: :trending,
          current_scope: Scope.unrestricted()
        })

      {:noreply, updated} = Index.handle_info(:load_data, socket)

      assert Enum.any?(updated.assigns.items, &(&1.title == MetadataStubProvider.movie_title()))
    end
  end

  describe "discover results (handle_info(:load_data, ...), category: :discover)" do
    # `Metadata.discover/2` calls `Relay.fetch_discover/3` with
    # `Metadata.default_relay_config/0` directly rather than through
    # `Provider.Registry`, so the stub provider above cannot intercept it.
    # Overriding `:metadata_relay_url` to a local Bypass is the seam
    # `library_picker_test.exs` already uses for this exact hazard.
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

    test "a category-restricted scope drops an out-of-bounds discover hit", %{bypass: bypass} do
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      # A unique year keeps this test's Metadata.discover/2 cache key from
      # colliding with any other test's, so no on_exit cache cleanup is
      # needed beyond what setup_metadata_stub already does.
      year = System.unique_integer([:positive])

      Bypass.expect_once(bypass, "GET", "/tmdb/movies/discover", fn conn ->
        body = %{
          "results" => [
            %{"id" => 42, "title" => "Live Action Thing", "release_date" => "2020-01-01"}
          ],
          "total_pages" => 1
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      socket =
        stub_socket(%{
          media_type: :movie,
          search_mode: false,
          search_query: "",
          category: :discover,
          selected_genres: [],
          selected_language: nil,
          selected_year: year,
          min_rating: nil,
          sort_by: "popularity.desc",
          current_scope: scope
        })

      {:noreply, updated} = Index.handle_info(:load_data, socket)

      # The stubbed hit carries no genre_ids, so it classifies as plain
      # "movie" -- out of bounds for a cartoon_movie-only scope.
      assert updated.assigns.items == []
    end
  end

  describe "recommendations rail (handle_async(:load_recommendations, ...))" do
    test "a category-restricted scope drops an out-of-bounds recommendation" do
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
      socket = stub_socket(%{current_scope: scope})

      {:noreply, updated} =
        Index.handle_async(:load_recommendations, {:ok, {:ok, [recommendation()]}}, socket)

      assert updated.assigns.selected_recommendations == []
    end

    test "an unrestricted scope keeps the recommendation" do
      socket = stub_socket(%{current_scope: Scope.unrestricted()})

      {:noreply, updated} =
        Index.handle_async(:load_recommendations, {:ok, {:ok, [recommendation()]}}, socket)

      assert length(updated.assigns.selected_recommendations) == 1
    end
  end
end
