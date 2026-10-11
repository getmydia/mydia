defmodule MydiaWeb.ImportMediaProviderToggleTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library.ImportCandidateGroup
  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp seed_group(lp, anchor_key, attrs) do
    import_candidate_fixture(
      Map.merge(
        %{
          library_path_id: lp.id,
          anchor_key: anchor_key,
          relative_path: "#{anchor_key}/file-1.mkv"
        },
        attrs
      )
    )
  end

  defp mount_import(conn, lp), do: live(conn, ~p"/import?library=#{lp.id}")

  defp open_match_search(view, lp, anchor_key) do
    group = ImportCandidates.get_group(lp.id, anchor_key)

    view
    |> element("#change-match-#{ImportCandidateGroup.dom_id(group)}")
    |> render_click()

    render_async(view)
  end

  test "a movies library's match modal has no provider toggle", %{conn: conn} do
    lp = library_path_fixture(%{type: "movies"})

    seed_group(lp, "Harbor Lights", %{provider_id: nil, confidence: nil, media_type: "movie"})

    {:ok, view, _html} = mount_import(conn, lp)
    open_match_search(view, lp, "Harbor Lights")

    assert has_element?(view, "#match-search-form")
    refute has_element?(view, "#match-provider-toggle")
  end

  test "the toggle searches TMDB and the picked result is stamped TMDB", %{conn: conn} do
    lp = library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})

    seed_group(lp, "Harbor Lights", %{provider_id: nil, confidence: nil, media_type: "tv_show"})

    {:ok, view, _html} = mount_import(conn, lp)
    open_match_search(view, lp, "Harbor Lights")

    assert has_element?(view, "#match-provider-toggle")
    assert has_element?(view, "#match-provider-tvdb[checked]")

    view |> element("#match-provider-tmdb") |> render_click()

    tmdb_id = MetadataStubProvider.series_tmdb_id()
    assert render_async(view) =~ "match-result-#{tmdb_id}-tmdb"

    view |> element("#match-result-#{tmdb_id}-tmdb") |> render_click()

    group = ImportCandidates.get_group(lp.id, "Harbor Lights")
    assert group.provider_type == "tmdb"
    assert has_element?(view, "#group-provider-badge-#{ImportCandidateGroup.dom_id(group)}")
  end
end
