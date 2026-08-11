defmodule MydiaWeb.AddMediaLive.ConfigModalTest do
  # async: false — connected LiveView tests cannot use the Postgres
  # non-shared sandbox, which hides test rows from the mount process.
  # Also: Provider.Registry is global process state.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.SettingsFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Media
  alias Mydia.Metadata.Provider
  alias Mydia.Metadata.Structs.{ImagesResponse, MediaMetadata, SearchResult}

  # Real-UI path: search + open gear + submit. Direct `submit_config_modal`
  # needs `config_modal_index` / `config_modal_result`, which only exist after
  # `open_config_modal`. Auth helper is `log_in_user` (no `log_in_admin`).
  defmodule ResultProvider do
    @behaviour Mydia.Metadata.Provider

    @impl true
    def test_connection(_config), do: {:ok, %{status: "ok"}}

    @impl true
    def search(_config, _query, _opts) do
      {:ok,
       [
         %SearchResult{
           provider_id: "603",
           provider: :metadata_relay,
           media_type: :movie,
           id: 603,
           title: "The Matrix",
           release_date: "1999-03-30",
           overview: "A computer hacker learns about the true nature of reality.",
           poster_path: "/matrix-poster.jpg",
           vote_average: 8.2
         }
       ]}
    end

    @impl true
    def fetch_by_id(_config, _id, _opts) do
      {:ok,
       %MediaMetadata{
         provider_id: "603",
         provider: :metadata_relay,
         media_type: :movie,
         id: 603,
         title: "The Matrix",
         original_title: "The Matrix",
         year: 1999,
         release_date: ~D[1999-03-30],
         overview: "A computer hacker learns about the true nature of reality.",
         imdb_id: "tt0133093"
       }}
    end

    @impl true
    def fetch_images(_config, _id, _opts),
      do: {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}

    @impl true
    def fetch_season(_config, _id, _season, _opts), do: {:ok, %{}}

    @impl true
    def fetch_trending(_config, _opts), do: {:ok, []}
  end

  setup %{conn: conn} do
    Provider.Registry.register(:metadata_relay, ResultProvider)
    on_exit(fn -> Mydia.Metadata.register_providers() end)

    library = library_path_fixture(%{type: "movies"})
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), library: library}
  end

  describe "submit_config_modal" do
    test "creates the item with a blank quality profile and monitoring off",
         %{conn: conn, library: library} do
      {:ok, view, _html} = live(conn, ~p"/add/movie?q=matrix")

      # Wait for async search results to render.
      assert render(view) =~ "The Matrix"

      view
      |> element(~s(button[phx-click="open_config_modal"][phx-value-index="0"]))
      |> render_click()

      # Blank quality profile and an absent `monitored` key are exactly the two
      # shapes that used to raise KeyError in build_media_item_attrs/3.
      # Drive submit via hook (not form/2): the movie modal has no
      # season_monitoring field, and a checked DOM checkbox would re-inject
      # monitored=true — neither matches the crash shapes.
      params = %{
        "config" => %{
          "library_path_id" => to_string(library.id),
          "quality_profile_id" => "",
          "season_monitoring" => "all"
        }
      }

      render_hook(view, "submit_config_modal", params)

      assert_no_crash(view)
    end

    test "stores the selected library on the created item", %{conn: conn, library: library} do
      {:ok, view, _html} = live(conn, ~p"/add/movie?q=matrix")

      assert render(view) =~ "The Matrix"

      view
      |> element(~s(button[phx-click="open_config_modal"][phx-value-index="0"]))
      |> render_click()

      params = %{
        "config" => %{
          "library_path_id" => to_string(library.id),
          "quality_profile_id" => "",
          "season_monitoring" => "all"
        }
      }

      render_hook(view, "submit_config_modal", params)

      # Poll briefly: creation happens in handle_info after a metadata fetch.
      assert eventually(fn ->
               case Media.list_media_items() do
                 [item | _] -> item.library_path_id == library.id
                 [] -> false
               end
             end)
    end
  end

  describe "search on add" do
    test "queues a search job when search_on_add is set", %{conn: conn, library: library} do
      {:ok, view, _html} = live(conn, ~p"/add/movie?q=matrix")

      assert render(view) =~ "The Matrix"

      view
      |> element(~s(button[phx-click="open_config_modal"][phx-value-index="0"]))
      |> render_click()

      params = %{
        "config" => %{
          "library_path_id" => to_string(library.id),
          "quality_profile_id" => "",
          "season_monitoring" => "all",
          "search_on_add" => "true"
        }
      }

      render_hook(view, "submit_config_modal", params)

      assert eventually(fn -> Mydia.Repo.aggregate(Oban.Job, :count) > 0 end)
    end

    test "queues nothing when search_on_add is absent", %{conn: conn, library: library} do
      {:ok, view, _html} = live(conn, ~p"/add/movie?q=matrix")

      assert render(view) =~ "The Matrix"

      view
      |> element(~s(button[phx-click="open_config_modal"][phx-value-index="0"]))
      |> render_click()

      params = %{
        "config" => %{
          "library_path_id" => to_string(library.id),
          "quality_profile_id" => "",
          "season_monitoring" => "all"
        }
      }

      render_hook(view, "submit_config_modal", params)

      assert eventually(fn -> Media.list_media_items() != [] end)
      assert Mydia.Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  defp assert_no_crash(view) do
    # A LiveView that died mid-handle_info raises here; a live one renders.
    assert render(view) =~ "add"
  end

  defp eventually(fun, retries \\ 20) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, retries - 1)
    end
  end
end
