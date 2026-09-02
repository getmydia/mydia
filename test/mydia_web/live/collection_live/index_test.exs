defmodule MydiaWeb.CollectionLive.IndexTest do
  # async: false - a connected LiveView cannot share the PostgreSQL sandbox
  # connection with an async test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

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

    test "reopening the gallery makes an added preset addable again", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()
      view |> element("#preset-add-decade_2000s") |> render_click()

      refute has_element?(view, "#preset-add-decade_2000s")

      view |> element("#close-preset-gallery") |> render_click()
      view |> element("#browse-presets-button") |> render_click()

      # The added state is scoped to one visit, so it can never outlive the
      # collection it describes. Duplicates are permitted by design; the
      # name-match hint warns without blocking.
      assert has_element?(view, "#preset-add-decade_2000s")
      refute has_element?(view, "#preset-added-decade_2000s")
      assert render(view) =~ "You already have a collection with this name."

      view |> element("#preset-add-decade_2000s") |> render_click()

      assert Collections.list_collections(user)
             |> Enum.count(&(&1.name == "2000s")) == 2
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

  describe "preset counts" do
    # Guards against the three count states being conflated. Design intent is
    # explicit that a loaded zero must render as "0 items" and stay addable,
    # never fall back to the not-yet-loaded spinner (a regression a naive
    # `if @count do ... else spinner end` would introduce silently).
    test "a preset with zero matches still shows \"0 items\" and stays addable",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()

      # No media exists yet, so every preset's count is a genuine, loaded
      # zero rather than "not loaded yet".
      render_async(view, 2000)

      assert has_element?(view, "#preset-card-decade_2000s", "0 items")
      assert has_element?(view, "#preset-add-decade_2000s")
      refute has_element?(view, "#preset-added-decade_2000s")

      add_button_html = view |> element("#preset-add-decade_2000s") |> render()
      refute add_button_html =~ "disabled"
    end

    test "a preset with matches shows the real count", %{conn: conn} do
      media_item_fixture(%{type: "movie", title: "Static Horizon", year: 2005})
      media_item_fixture(%{type: "movie", title: "Nebula Drift", year: 2005})
      # Outside the 2000s range: proves the count is a real query result and
      # not just "however many media items exist".
      media_item_fixture(%{type: "movie", title: "Copper Skyline", year: 1975})

      {:ok, view, _html} = live(conn, ~p"/collections")
      view |> element("#browse-presets-button") |> render_click()

      render_async(view, 2000)

      assert has_element?(view, "#preset-card-decade_2000s", "2 items")
    end

    # render_click's return value is a snapshot taken synchronously while the
    # LiveView handles the click and replies over the test channel, strictly
    # before it can process the start_async task's completion message (a
    # GenServer only picks up its next mailbox message once the current one
    # is fully handled). So this does not race the async count query,
    # regardless of how fast that query runs.
    test "counts start as spinners before the async query resolves", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")

      html = view |> element("#browse-presets-button") |> render_click()

      assert html =~ "loading loading-spinner loading-xs"
      refute html =~ "0 items"
    end
  end
end
