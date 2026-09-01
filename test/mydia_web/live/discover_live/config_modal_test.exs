defmodule MydiaWeb.DiscoverLive.ConfigModalTest do
  # async: false: connected LiveView tests cannot use the Postgres
  # non-shared sandbox, which hides test rows from the mount process.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list on
    # connected mount (#530), and the plain `/discover` mount (no search
    # query) falls into the default :trending category.
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])

    provider_id = unique_provider_id()

    warm_movie_search_cache("quiet harbour", [], [
      %{"id" => provider_id, "title" => "Quiet Harbour", "release_date" => "2024-05-01"}
    ])

    user = user_fixture(%{role: "admin"})
    library_path_fixture(%{type: :movies})
    quality_profile_fixture()

    %{conn: log_in_user(conn, user), provider_id: provider_id}
  end

  test "the modal is closed on mount", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    refute has_element?(view, "#add-config-modal[open]")
  end

  # Reaching Configure requires opening the library-picker caret first: the
  # entry lives inside library_picker_dialog/1 (a single page-level element,
  # so its DOM id cannot repeat per card), and that dialog only renders once
  # @picker is set. With only one candidate library the caret would normally
  # stay hidden (library_picker_button/1's `> 1` gate), so DiscoverLive marks
  # its caret always_show_caret: true. Configure must stay reachable
  # regardless of how many libraries exist, including zero.
  test "the configure entry opens the modal seeded with resolved defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

    view |> element("[data-test='library-picker-caret']") |> render_click()
    view |> element("#discover-configure-add") |> render_click()

    assert has_element?(view, "#add-config-modal[open]")
    assert has_element?(view, "#add-config-form select[name='config[library_path_id]']")
    assert has_element?(view, "#add-config-form select[name='config[quality_profile_id]']")
    # A movie has no seasons: the season monitoring select is guarded on
    # @media_type == :tv_show and must not render here.
    refute has_element?(view, "#add-config-form select[name='config[season_monitoring]']")
    assert has_element?(view, "#add-config-form input[name='config[monitored]'][type=checkbox]")

    assert has_element?(
             view,
             "#add-config-form input[name='config[search_on_add]'][type=checkbox]"
           )
  end

  test "closing the modal leaves nothing added", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

    view |> element("[data-test='library-picker-caret']") |> render_click()
    view |> element("#discover-configure-add") |> render_click()
    view |> element("#add-config-modal button", "Cancel") |> render_click()

    refute has_element?(view, "#add-config-modal[open]")
    assert Mydia.Media.list_media_items() == []
  end

  # submit_add_config's own glue (params["monitored"] == "true", presence/1 on
  # the selects, and the add_config map lookup) is what these cover.
  # AddDefaults.resolve/3, to_add_opts/1 and handle_add_media_to_library/5 are
  # exercised elsewhere (add_defaults_test.exs, auto_search_test.exs).
  describe "submit_add_config" do
    setup %{provider_id: provider_id} do
      chosen_library = library_path_fixture(%{type: :movies})
      profile = quality_profile_fixture()

      # The add flow's own metadata fetch (Add.from_provider -> Metadata.fetch_by_id)
      # is uncached, unlike the search lookup warmed above, so it needs its own
      # Bypass and a temporary metadata_relay_url swap rather than a cache warm.
      bypass = Bypass.open()
      previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_metadata_relay_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      Bypass.expect(bypass, "GET", "/tmdb/movies/#{provider_id}", fn conn ->
        body = %{
          "id" => provider_id,
          "title" => "Quiet Harbour",
          "release_date" => "2024-05-01",
          "belongs_to_collection" => nil
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      %{chosen_library: chosen_library, profile: profile}
    end

    test "an explicit library, quality profile, monitored and search_on_add choice all persist",
         %{conn: conn, provider_id: provider_id, chosen_library: chosen_library, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

      view |> element("[data-test='library-picker-caret']") |> render_click()
      view |> element("#discover-configure-add") |> render_click()

      view
      |> element("#add-config-form")
      |> render_submit(%{
        "config" => %{
          "library_path_id" => to_string(chosen_library.id),
          "quality_profile_id" => to_string(profile.id),
          "monitored" => "true",
          "search_on_add" => "true"
        }
      })

      media_item = wait_until_media_item(provider_id)

      assert media_item.library_path_id == chosen_library.id
      assert media_item.quality_profile_id == profile.id
      assert media_item.monitored == true

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{mode: "specific", media_item_id: media_item.id}
      )
    end

    # A blank quality profile and an absent monitored key are exactly the two
    # shapes that used to raise KeyError in build_media_item_attrs/3 on the
    # deleted Add page. Driven via the hook path rather than form/2: a real
    # form always resubmits the hidden monitored fallback, so an absent key
    # can never reach the handler through DOM serialization.
    test "a blank quality profile and an absent monitored key do not crash the add",
         %{conn: conn, provider_id: provider_id, chosen_library: chosen_library} do
      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

      view |> element("[data-test='library-picker-caret']") |> render_click()
      view |> element("#discover-configure-add") |> render_click()

      render_hook(view, "submit_add_config", %{
        "config" => %{
          "library_path_id" => to_string(chosen_library.id),
          "quality_profile_id" => ""
        }
      })

      media_item = wait_until_media_item(provider_id)

      assert media_item.library_path_id == chosen_library.id
      assert media_item.quality_profile_id == nil
    end

    test "search_on_add omitted queues nothing",
         %{conn: conn, provider_id: provider_id, chosen_library: chosen_library} do
      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

      view |> element("[data-test='library-picker-caret']") |> render_click()
      view |> element("#discover-configure-add") |> render_click()

      render_hook(view, "submit_add_config", %{
        "config" => %{
          "library_path_id" => to_string(chosen_library.id),
          "quality_profile_id" => "",
          "monitored" => "true"
        }
      })

      media_item = wait_until_media_item(provider_id)

      refute_enqueued(worker: Mydia.Jobs.MovieSearch, args: %{media_item_id: media_item.id})
    end
  end

  # The add completes in a handle_info the submit's render_submit/render_hook
  # round trip does not wait on: it fetches metadata over Bypass before
  # creating the row. Matches the wait_until/1 helper hide_owned_test.exs
  # uses for the same reason.
  defp wait_until_media_item(provider_id, retries \\ 200)

  defp wait_until_media_item(provider_id, 0) do
    flunk("media item for provider_id=#{provider_id} was not created in time")
  end

  defp wait_until_media_item(provider_id, retries) do
    case Mydia.Media.get_media_item_by_tmdb(provider_id) do
      nil ->
        Process.sleep(10)
        wait_until_media_item(provider_id, retries - 1)

      media_item ->
        media_item
    end
  end
end
