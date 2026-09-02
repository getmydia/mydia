defmodule MydiaWeb.DiscoverLive.ConfigModalTest do
  # async: false: connected LiveView tests cannot use the Postgres
  # non-shared sandbox, which hides test rows from the mount process.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataCacheHelpers

  # wait_until_media_item/1 returns as soon as the media_items row lands, but
  # the search job is inserted after it, in the same handle_info. A bare
  # assert_enqueued therefore races the insert: on PostgreSQL it failed while
  # reporting the very job it was looking for under "Instead found", because
  # the job arrived between the matching query and the error message's own
  # query. Oban's timeout form retries instead.
  @enqueue_timeout 2_000

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
        [
          worker: Mydia.Jobs.MovieSearch,
          args: %{mode: "specific", media_item_id: media_item.id}
        ],
        @enqueue_timeout
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

    # The other tests here drive the submit through render_submit/2 and
    # render_hook/3 with explicit param maps, which bypass DOM serialization
    # entirely. A checkbox with no `value` attribute submits "on", and
    # `params["search_on_add"] == "true"` reads that as false, so a checked
    # toggle queued nothing. Only a real form/2 submit catches that.
    test "a checked search_on_add toggle survives DOM serialization",
         %{conn: conn, provider_id: provider_id} do
      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

      view |> element("[data-test='library-picker-caret']") |> render_click()
      view |> element("#discover-configure-add") |> render_click()

      # media.auto_search_on_add defaults to true, so the toggle renders
      # checked and the form carries it with no explicit override.
      assert has_element?(
               view,
               "#add-config-form input[type=checkbox][name='config[search_on_add]'][value='true']"
             )

      view |> form("#add-config-form") |> render_submit()

      media_item = wait_until_media_item(provider_id)

      assert_enqueued(
        [
          worker: Mydia.Jobs.MovieSearch,
          args: %{mode: "specific", media_item_id: media_item.id}
        ],
        @enqueue_timeout
      )
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

      # Given a timeout for the mirror-image reason: without one this would
      # also pass while the insert was merely still in flight.
      refute_enqueued(
        [worker: Mydia.Jobs.MovieSearch, args: %{media_item_id: media_item.id}],
        @enqueue_timeout
      )
    end
  end

  # Configure is also reachable from a caret inside the recommendations rail
  # while the trending-detail modal is open (TrendingDetailModal's own
  # header caret needs the same fix, but the rail is where the reviewed
  # regression was found). Opening it clears @library_picker, so
  # picker_open alone reads false again the instant Configure opens; without
  # TrendingDetailModal's config_open guard, one Escape press fires both
  # close_add_config and close_details and silently closes the detail view.
  describe "Escape while the detail modal is also open" do
    setup %{provider_id: provider_id} do
      # A second candidate library so the caret is visible on its ordinary
      # `> 1` gate: the recommendations rail's cards do not carry Discover's
      # main-grid always_show_caret override.
      library_path_fixture(%{type: :movies})

      recommended_id = unique_provider_id()

      warm_recommendations_cache(provider_id, :movie, [
        %{"id" => recommended_id, "title" => "Second Reef", "release_date" => "2023-01-01"}
      ])

      bypass = Bypass.open()
      previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_metadata_relay_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      # The detail modal's own metadata fetch (fetch_detail_metadata ->
      # Metadata.fetch_by_id) is uncached, matching the add flow's own fetch
      # in the describe block above.
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

      %{recommended_id: recommended_id}
    end

    test "pressing Escape while Configure is open over the detail modal closes only Configure",
         %{conn: conn, provider_id: provider_id, recommended_id: recommended_id} do
      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{provider_id}']")
      |> render_click()

      assert has_element?(view, "#discover-detail-modal[open]")

      render_async(view, 5000)

      rail_caret =
        "#discover-recommendations-rail-item-#{recommended_id} [data-test='library-picker-caret']"

      assert has_element?(view, rail_caret)

      view |> element(rail_caret) |> render_click()
      view |> element("#discover-configure-add") |> render_click()

      assert has_element?(view, "#add-config-modal[open]")

      # The detail modal's own Escape binding must be suppressed while
      # Configure is open, or a real Escape press would fire both handlers.
      refute has_element?(view, "#discover-detail-modal[phx-window-keydown]")

      view |> element("#add-config-modal") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#add-config-modal[open]")
      assert has_element?(view, "#discover-detail-modal[open]")
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
