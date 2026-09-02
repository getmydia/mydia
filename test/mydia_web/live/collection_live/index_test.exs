defmodule MydiaWeb.CollectionLive.IndexTest do
  # async: false - a connected LiveView cannot share the PostgreSQL sandbox
  # connection with an async test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Collections

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "preset gallery" do
    test "the browse presets button opens the gallery", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")

      refute has_element?(view, "#preset-gallery-modal")

      view |> element("#browse-presets-button") |> render_click()

      assert has_element?(view, "#preset-gallery-modal")
      assert has_element?(view, "#preset-card-decade_2000s")
      assert has_element?(view, "#preset-card-highly_rated")
    end

    test "the gallery renders a card for every preset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()

      for preset <- Collections.Presets.list() do
        assert has_element?(view, "#preset-card-#{preset.key}"),
               "no card rendered for preset #{preset.key}"
      end
    end

    test "adding a preset creates a collection and flips the card", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()

      view |> element("#preset-add-decade_2000s") |> render_click()

      collections = Collections.list_collections(user)
      assert Enum.any?(collections, &(&1.name == "2000s" and &1.type == "smart"))

      # The gallery stays open so several presets can be added in a row.
      assert has_element?(view, "#preset-gallery-modal")
      assert has_element?(view, "#preset-added-decade_2000s")
      refute has_element?(view, "#preset-add-decade_2000s")
    end

    test "several presets can be added without reopening the gallery", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()

      view |> element("#preset-add-decade_2000s") |> render_click()
      view |> element("#preset-add-decade_2010s") |> render_click()

      names = Collections.list_collections(user) |> Enum.map(& &1.name)
      assert "2000s" in names
      assert "2010s" in names
    end

    test "an unknown preset key flashes instead of crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()

      html = render_click(view, "add_preset", %{"key" => "no_such_preset"})

      assert html =~ "no longer available"
      assert has_element?(view, "#preset-gallery-modal")
    end

    test "the gallery closes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()
      assert has_element?(view, "#preset-gallery-modal")

      view |> element("#close-preset-gallery") |> render_click()
      refute has_element?(view, "#preset-gallery-modal")
    end
  end
end
