defmodule MydiaWeb.RequestMediaLive.IndexTest do
  # Not async: the provider registry is global process state, and a connected
  # LiveView mount runs in a separate process from the test (see the note in
  # DownloadsLive.IndexTest about the non-shared Postgres sandbox).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Provider
  alias Mydia.Metadata.Structs.SearchResult

  # `Metadata.search/3` returns %SearchResult{} structs, not maps. Reading them
  # with bracket syntax raised UndefinedFunctionError (SearchResult.fetch/2),
  # so every guest request search blew up as soon as it had a result to render.
  defmodule ResultProvider do
    @behaviour Mydia.Metadata.Provider

    alias Mydia.Metadata.Structs.ImagesResponse

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
    def fetch_by_id(_config, _id, _opts), do: {:ok, %{}}

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

    user = create_test_user()
    %{conn: log_in_user(conn, user)}
  end

  describe "search results" do
    test "renders SearchResult structs returned by the provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/request/movie?q=matrix")

      html = render(view)

      assert html =~ "Search Results"
      assert html =~ "The Matrix"
      assert html =~ "true nature of reality"
      assert html =~ "matrix-poster.jpg"
      assert html =~ "1999"
    end

    test "renders the request modal for a selected SearchResult", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/request/movie?q=matrix")

      html =
        view
        |> element(~s(button[phx-click="open_request_modal"][phx-value-index="0"]))
        |> render_click()

      assert html =~ "Request Media"
      assert html =~ "The Matrix"
      assert html =~ "true nature of reality"
    end
  end
end
