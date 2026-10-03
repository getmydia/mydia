defmodule MydiaWeb.ImportMediaRestrictedMatchTest do
  @moduledoc """
  `/import` and `/review` are open to every signed-in account. The "Change
  match" search lists provider hits, which must go through
  `Mydia.Media.RemoteFilter` so a restricted account cannot pick a title
  outside its limits.
  """

  # The stub provider registry and the metadata cache are global.
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers, only: [warm_remote_signals: 3]
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures
  import Phoenix.LiveViewTest

  alias Mydia.Library.ImportCandidateGroup
  alias Mydia.Media.RemoteSignals
  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  setup do
    warm_remote_signals(
      {:tmdb, MetadataStubProvider.movie_tmdb_id()},
      :movie,
      %RemoteSignals{category: "movie"}
    )

    :ok
  end

  # Opens the match modal on a movie group and reports whether the stub movie
  # is offered.
  defp movie_offered?(conn, user) do
    lp = library_path_fixture(%{type: "movies"})

    import_candidate_fixture(%{
      library_path_id: lp.id,
      anchor_key: "stubmovie",
      relative_path: "Stub Movie (2020)/stub.mkv",
      provider_id: "9999",
      provider_type: "tmdb",
      title: "Stub Movie",
      year: 2020,
      media_type: "movie",
      confidence: 0.7
    })

    group = Mydia.ImportCandidates.get_group(lp.id, "stubmovie")

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/import")

    view
    |> element("#change-match-#{ImportCandidateGroup.dom_id(group)}")
    |> render_click()

    render_async(view)

    has_element?(view, "#match-result-#{MetadataStubProvider.movie_tmdb_id()}-metadata_relay")
  end

  test "a category-restricted account is not offered an out-of-bounds title", %{conn: conn} do
    user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    refute movie_offered?(conn, user)
  end

  test "an account allowed that category is offered it", %{conn: conn} do
    user = restricted_user_fixture(%{allowed_categories: ["movie"]})

    assert movie_offered?(conn, user)
  end

  test "an unrestricted account is offered it", %{conn: conn} do
    assert movie_offered?(conn, user_fixture())
  end
end
