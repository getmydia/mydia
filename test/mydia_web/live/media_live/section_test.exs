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
          type: "manual",
          visibility: "private",
          pinned_position: 0
        })

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/sections/#{theirs.id}")
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
end
