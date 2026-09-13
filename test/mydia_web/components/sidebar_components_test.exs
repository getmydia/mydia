defmodule MydiaWeb.SidebarComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias MydiaWeb.SidebarComponents

  defp count(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp render_item(attrs) do
    defaults = %{path: "/downloads", icon: "hero-arrow-down-tray", label: "Downloads"}
    render_component(&SidebarComponents.nav_item/1, Map.merge(defaults, attrs))
  end

  describe "nav_active?/3" do
    test "exact matches only the path itself" do
      assert SidebarComponents.nav_active?("/", "/", true)
      refute SidebarComponents.nav_active?("/movies", "/", true)
    end

    test "prefix matches sub-paths but not look-alike siblings" do
      assert SidebarComponents.nav_active?("/movies", "/movies", false)
      assert SidebarComponents.nav_active?("/movies/42", "/movies", false)
      refute SidebarComponents.nav_active?("/movies-archive", "/movies", false)
      refute SidebarComponents.nav_active?(nil, "/movies", false)
    end
  end

  describe "nav_item/1" do
    test "links to its path and marks the current page with menu-active" do
      html = render_item(%{current_path: "/downloads/5"})
      assert count(html, ~s|li > a.menu-active[href="/downloads"]|) == 1

      html = render_item(%{current_path: "/movies"})
      assert count(html, ~s|a[href="/downloads"]|) == 1
      assert count(html, "a.menu-active") == 0
    end

    test "shows an attention badge only above zero" do
      html = render_item(%{badge: 3, badge_id: "nav-downloads-badge"})
      assert count(html, "#nav-downloads-badge.badge.badge-primary") == 1
      assert text(html, "#nav-downloads-badge") == "3"

      assert count(render_item(%{badge: 0, badge_id: "nav-downloads-badge"}), ".badge") == 0
      assert count(render_item(%{}), ".badge") == 0
    end

    test "shows a total as a muted number, not a badge" do
      html = render_item(%{count: 412, count_id: "nav-movie-count"})
      assert text(html, "#nav-movie-count") == "412"
      assert count(html, "#nav-movie-count.badge") == 0

      assert text(render_item(%{count: 0, count_id: "nav-movie-count"}), "#nav-movie-count") ==
               "0"
    end
  end

  describe "nav_title/1" do
    test "renders a menu-title with its label and action" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SidebarComponents.nav_title id="nav-title-library" label="Library">
          <:action><a id="add-thing" href="/sections/new">+</a></:action>
        </SidebarComponents.nav_title>
        """)

      assert count(html, "li#nav-title-library.menu-title") == 1
      assert text(html, "#nav-title-library > span") == "Library"
      assert count(html, "#nav-title-library a#add-thing") == 1
    end

    test "renders without an action" do
      html =
        render_component(&SidebarComponents.nav_title/1, %{id: "nav-title-admin", label: "Admin"})

      assert text(html, "#nav-title-admin") == "Admin"
    end
  end
end
