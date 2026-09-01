defmodule MydiaWeb.MediaLive.SectionTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections

  setup %{conn: conn} do
    user = user_fixture(%{role: "admin"})

    anime =
      categorized_media_item_fixture(
        %{title: "Comet Circuit", type: "tv_show"},
        :anime_series
      )

    live =
      categorized_media_item_fixture(
        %{title: "Harbor Lights", type: "tv_show"},
        :tv_show
      )

    {:ok, section} =
      Collections.create_collection(user, %{
        name: "Anime",
        type: "smart",
        visibility: "private",
        smart_rules:
          Jason.encode!(%{
            "conditions" => [
              %{
                "field" => "category",
                "operator" => "in",
                "value" => ["anime_movie", "anime_series"]
              }
            ]
          }),
        pinned_position: 0,
        sidebar_icon: "hero-sparkles",
        exclusive: true
      })

    %{conn: log_in_user(conn, user), user: user, anime: anime, live: live, section: section}
  end

  describe "GET /sections/:id" do
    test "renders only the items matching the section rules", %{
      conn: conn,
      section: section,
      anime: anime,
      live: live
    } do
      {:ok, _view, html} = live(conn, ~p"/sections/#{section.id}")

      assert html =~ anime.title
      refute html =~ live.title
    end

    test "shows the section name as the page heading", %{conn: conn, section: section} do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      assert has_element?(view, "#section-heading", "Anime")
    end

    test "offers the same batch toolbar as the library pages", %{conn: conn, section: section} do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      view |> element("#toggle-selection-mode") |> render_click()

      assert has_element?(view, "#batch-monitor")
    end

    test "a batch operation applies to rule-sourced items", %{
      conn: conn,
      section: section,
      anime: anime
    } do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      view |> element("#toggle-selection-mode") |> render_click()
      view |> element("#select-all") |> render_click()
      view |> element("#batch-unmonitor") |> render_click()

      refute Mydia.Media.get_media_item!(anime.id).monitored
    end

    test "redirects when the section belongs to someone else", %{conn: conn} do
      stranger = user_fixture()

      {:ok, theirs} =
        Collections.create_collection(stranger, %{
          name: "Private",
          type: "smart",
          visibility: "private",
          smart_rules:
            Jason.encode!(%{
              "conditions" => [
                %{"field" => "category", "operator" => "in", "value" => ["anime_movie"]}
              ]
            }),
          pinned_position: 0
        })

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/sections/#{theirs.id}")
    end

    test "redirects rather than rendering the whole library for a manual collection", %{
      conn: conn,
      user: user
    } do
      # A manual collection has no smart_rules, so a section page for one
      # (pinned before the type: "smart" guard existed) would otherwise fall
      # back to an unfiltered query. Bypass pin_section/3 with an update, the
      # same way a pre-guard row would have gotten here.
      {:ok, manual} =
        Collections.create_collection(user, %{
          name: "Watchlist",
          type: "manual",
          visibility: "private"
        })

      manual
      |> Ecto.Changeset.change(%{pinned_position: 0})
      |> Mydia.Repo.update!()

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/sections/#{manual.id}")
    end

    test "renders an error state rather than an empty library for broken rules", %{
      conn: conn,
      section: section
    } do
      section
      |> Ecto.Changeset.change(%{smart_rules: "{not json"})
      |> Mydia.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      assert has_element?(view, "#section-rules-error")
    end

    test "a library scan broadcast does not crash section mode", %{
      conn: conn,
      section: section
    } do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      send(view.pid, {:library_scan_started, %{type: :series}})

      assert render(view) =~ "Anime"
    end
  end

  describe "exclusive sections and the built-in pages" do
    test "the TV page hides the claimed categories", %{
      conn: conn,
      anime: anime,
      live: live
    } do
      {:ok, _view, html} = live(conn, ~p"/tv")

      assert html =~ live.title
      refute html =~ anime.title
    end

    test "the TV page keeps everything when the section is not exclusive", %{
      conn: conn,
      user: user,
      section: section,
      anime: anime
    } do
      {:ok, _} = Collections.update_collection(user, section, %{exclusive: false})

      {:ok, _view, html} = live(conn, ~p"/tv")

      assert html =~ anime.title
    end

    test "the sidebar count agrees with the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tv")

      assert has_element?(view, "#nav-tv-count", "1")
    end

    test "the page explains where the hidden items went", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tv")

      assert has_element?(view, "#excluded-notice")
    end

    test "the notice names the single claiming section and links to it", %{
      conn: conn,
      section: section
    } do
      {:ok, view, _html} = live(conn, ~p"/tv")

      assert has_element?(
               view,
               ~s(#excluded-notice a[href="/sections/#{section.id}"]),
               "Anime"
             )
    end

    test "the notice falls back to aggregate wording when more than one section claims", %{
      conn: conn,
      user: user
    } do
      {:ok, _other} =
        Collections.create_collection(user, %{
          name: "Retro",
          type: "smart",
          visibility: "private",
          smart_rules:
            Jason.encode!(%{
              "conditions" => [
                %{"field" => "category", "operator" => "in", "value" => ["cartoon_series"]}
              ]
            }),
          pinned_position: 1,
          exclusive: true
        })

      {:ok, view, _html} = live(conn, ~p"/tv")

      assert has_element?(view, "#excluded-notice", "in your pinned sections")
      refute has_element?(view, "#excluded-notice a")
    end

    test "the sidebar shows the pinned section", %{conn: conn, section: section} do
      {:ok, view, _html} = live(conn, ~p"/tv")

      assert has_element?(view, "#nav-section-#{section.id}", "Anime")
    end

    test "the sidebar offers an add-section entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tv")

      assert has_element?(view, "#nav-add-section")
    end

    test "another user's sidebar has no sections", %{conn: _conn} do
      other = user_fixture(%{role: "admin"})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), other)

      {:ok, view, _html} = live(conn, ~p"/tv")

      refute has_element?(view, "[id^='nav-section-']")
      assert Mydia.Collections.list_pinned_sections(other) == []
    end
  end

  describe "section settings" do
    test "unpinning removes the section and returns to the library", %{
      conn: conn,
      user: user,
      section: section
    } do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      view |> element("#open-section-settings") |> render_click()

      {:error, {:live_redirect, %{to: "/tv"}}} =
        view |> element("#unpin-section") |> render_click()

      assert Collections.list_pinned_sections(user) == []
      assert Collections.get_collection(user, section.id)
    end

    test "unpinning restores the items to the TV page", %{
      conn: conn,
      section: section,
      anime: anime
    } do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")
      view |> element("#open-section-settings") |> render_click()
      view |> element("#unpin-section") |> render_click()

      {:ok, _view, html} = live(conn, ~p"/tv")

      assert html =~ anime.title
    end

    test "renaming the section updates the heading", %{conn: conn, section: section} do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      view |> element("#open-section-settings") |> render_click()

      view
      |> form("#section-settings-form", section: %{name: "Animation", exclusive: "true"})
      |> render_submit()

      assert has_element?(view, "#section-heading", "Animation")
    end

    test "the exclusive toggle is absent when the rules are not category-only", %{
      conn: conn,
      user: user
    } do
      {:ok, complex} =
        Collections.create_collection(user, %{
          name: "Recent",
          type: "smart",
          visibility: "private",
          smart_rules:
            Jason.encode!(%{
              "conditions" => [%{"field" => "year", "operator" => "gte", "value" => 2020}]
            }),
          pinned_position: 1
        })

      {:ok, view, _html} = live(conn, ~p"/sections/#{complex.id}")
      view |> element("#open-section-settings") |> render_click()

      refute has_element?(view, "#section-exclusive-toggle")
    end
  end

  describe "section settings ownership" do
    test "the gear icon is shown to the section's owner", %{conn: conn, section: section} do
      {:ok, view, _html} = live(conn, ~p"/sections/#{section.id}")

      assert has_element?(view, "#open-section-settings")
    end

    test "the gear icon is hidden from a viewer who does not own a shared section", %{
      user: owner
    } do
      {:ok, shared} =
        Collections.create_collection(owner, %{
          name: "Everyone's Picks",
          type: "smart",
          visibility: "shared",
          smart_rules:
            Jason.encode!(%{
              "conditions" => [
                %{"field" => "category", "operator" => "in", "value" => ["anime_movie"]}
              ]
            }),
          pinned_position: 1
        })

      viewer = user_fixture(%{role: "admin"})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), viewer)

      {:ok, view, _html} = live(conn, ~p"/sections/#{shared.id}")

      refute has_element?(view, "#open-section-settings")
    end

    test "a viewer who does not own the section cannot save changes to it either", %{
      user: owner
    } do
      {:ok, shared} =
        Collections.create_collection(owner, %{
          name: "Everyone's Picks",
          type: "smart",
          visibility: "shared",
          smart_rules:
            Jason.encode!(%{
              "conditions" => [
                %{"field" => "category", "operator" => "in", "value" => ["anime_movie"]}
              ]
            }),
          pinned_position: 1
        })

      viewer = user_fixture(%{role: "admin"})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), viewer)

      {:ok, view, _html} = live(conn, ~p"/sections/#{shared.id}")

      render_click(view, "save_section", %{
        "section" => %{
          "name" => "Hijacked",
          "sidebar_icon" => "hero-fire",
          "exclusive" => "false"
        }
      })

      assert Collections.get_collection_by_id(shared.id).name == "Everyone's Picks"
    end
  end

  describe "anime nudge" do
    setup %{user: user, section: section} do
      # These tests are about a library with no anime section yet. Rebind
      # :section to the fresh struct: reusing the stale pre-unpin one would let
      # a later pin_section/3 in the same test see no field-level change (its
      # in-memory pinned_position/exclusive already matched the intended
      # values), so Ecto would silently skip persisting them.
      {:ok, section} = Collections.unpin_section(user, section)
      %{section: section}
    end

    test "does not appear below the threshold", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tv")

      refute has_element?(view, "#anime-nudge")
    end

    test "appears once the library has enough anime", %{conn: conn} do
      for n <- 1..10 do
        categorized_media_item_fixture(
          %{title: "Signal Garden #{n}", type: "tv_show"},
          :anime_series
        )
      end

      {:ok, view, _html} = live(conn, ~p"/tv")

      assert has_element?(view, "#anime-nudge")
    end

    test "does not appear when a section already claims anime", %{
      conn: conn,
      user: user,
      section: section
    } do
      for n <- 1..10 do
        categorized_media_item_fixture(
          %{title: "Signal Garden #{n}", type: "tv_show"},
          :anime_series
        )
      end

      {:ok, _} = Collections.pin_section(user, section, exclusive: true)

      {:ok, view, _html} = live(conn, ~p"/tv")

      refute has_element?(view, "#anime-nudge")
    end

    test "dismissal survives a remount", %{conn: conn} do
      for n <- 1..10 do
        categorized_media_item_fixture(
          %{title: "Signal Garden #{n}", type: "tv_show"},
          :anime_series
        )
      end

      {:ok, view, _html} = live(conn, ~p"/tv")
      view |> element("#dismiss-anime-nudge") |> render_click()

      {:ok, view2, _html} = live(conn, ~p"/tv")
      refute has_element?(view2, "#anime-nudge")
    end

    test "accepting creates the anime section", %{conn: conn, user: user} do
      for n <- 1..10 do
        categorized_media_item_fixture(
          %{title: "Signal Garden #{n}", type: "tv_show"},
          :anime_series
        )
      end

      {:ok, view, _html} = live(conn, ~p"/tv")

      {:error, {:live_redirect, %{to: path}}} =
        view |> element("#accept-anime-nudge") |> render_click()

      assert [created] = Collections.list_pinned_sections(user)
      assert created.name == "Anime"
      assert path == "/sections/#{created.id}"
    end
  end
end
