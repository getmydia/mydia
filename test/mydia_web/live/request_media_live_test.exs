defmodule MydiaWeb.RequestMediaLive.IndexTest do
  # Not async: the provider registry is global process state, and a connected
  # LiveView mount runs in a separate process from the test (see the note in
  # DownloadsLive.IndexTest about the non-shared Postgres sandbox).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

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

  describe "a restricted account submitting a request" do
    # `submit_request_modal` used to fall through to the generic
    # `{:error, changeset} -> to_form(changeset, as: :request)` clause for any
    # error MediaRequests.create_request/3 returned it hadn't named explicitly,
    # which raised Protocol.UndefinedError the moment that value could be the
    # bare atom :restricted rather than an Ecto.Changeset. This is the guest
    # request flow the whole access-restriction feature exists for.
    #
    # Overrides the module's ResultProvider (whose fetch_by_id/3 returns a
    # bare %{}, fine for the tests above since they never fetch full
    # metadata) with the shared stub, which returns a real %MediaMetadata{}
    # -- required here because a restricted scope now triggers exactly that
    # fetch to judge the request.
    #
    # An age limit, not a category limit: `MydiaWeb.RemoteFilter` filters
    # `:search_results` by category using the genre ids TMDB search returns,
    # but TMDB search carries no certification and RemoteFilter does not
    # filter search hits by age (see its moduledoc) -- so the stub movie still
    # reaches this page's list. The stub's full metadata carries no
    # content_rating, which `Mydia.Media.ContentRating` treats as unrated, and
    # an unrated title is hidden under an active age limit. That is what
    # keeps the write-time `Media.writable?/2` check the one that catches it,
    # reproducing the exact gap this test was written to guard: a search hit
    # can be shown that a submit must still refuse.
    import Mydia.MetadataStub

    alias Mydia.MetadataStubProvider

    setup :setup_metadata_stub

    setup %{conn: conn} do
      restricted = restricted_user_fixture(%{role: "user", max_content_age: 12})

      %{conn: log_in_user(conn, restricted)}
    end

    test "an out-of-bounds request flashes a friendly message instead of raising",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/request/movie?q=stub")

      # Visible: RemoteFilter does not filter search results on age.
      assert render(view) =~ MetadataStubProvider.movie_title()

      view
      |> element(~s(button[phx-click="open_request_modal"][phx-value-index="0"]))
      |> render_click()

      html =
        view
        |> form("#request-modal-form", request: %{requester_notes: ""})
        |> render_submit()

      assert html =~ "This title is outside what your account is allowed to access."

      refute Mydia.MediaRequests.pending_request_exists?(MetadataStubProvider.movie_tmdb_id())
    end
  end
end
