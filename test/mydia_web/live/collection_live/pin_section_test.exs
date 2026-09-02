defmodule MydiaWeb.CollectionLive.PinSectionTest do
  # async: false — a connected LiveView cannot share the PostgreSQL sandbox
  # connection with an async test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Collections

  setup %{conn: conn} do
    user = user_fixture(%{role: "admin"})
    %{conn: log_in_user(conn, user), user: user}
  end

  defp smart_collection(user, attrs \\ %{}) do
    {:ok, collection} =
      Collections.create_collection(
        user,
        Map.merge(
          %{
            name: "Anime",
            type: "smart",
            visibility: "private",
            smart_rules:
              Jason.encode!(%{
                "conditions" => [
                  %{"field" => "category", "operator" => "in", "value" => ["anime_movie"]}
                ]
              })
          },
          attrs
        )
      )

    collection
  end

  defp manual_collection(user, attrs \\ %{}) do
    {:ok, collection} =
      Collections.create_collection(
        user,
        Map.merge(%{name: "Watchlist", type: "manual", visibility: "private"}, attrs)
      )

    collection
  end

  describe "pinning" do
    test "pinning a smart collection adds it to the sidebar, lands on the section and flashes",
         %{conn: conn, user: user} do
      collection = smart_collection(user)

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

      assert has_element?(view, "#pin-collection", "Pin to sidebar")

      {:ok, section_view, html} =
        view
        |> element("#pin-collection")
        |> render_click()
        |> follow_redirect(conn, ~p"/sections/#{collection.id}")

      assert html =~ "Pinned to sidebar"
      assert section_view
      assert [pinned] = Collections.list_pinned_sections(user)
      assert pinned.id == collection.id
    end
  end

  describe "unpinning" do
    test "unpinning clears the sidebar entry and flips the button back", %{
      conn: conn,
      user: user
    } do
      collection = smart_collection(user, %{pinned_position: 0})

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

      assert has_element?(view, "#unpin-collection", "Unpin from sidebar")

      html = view |> element("#unpin-collection") |> render_click()

      assert html =~ "Removed from sidebar"
      assert has_element?(view, "#pin-collection", "Pin to sidebar")
      refute has_element?(view, "#unpin-collection")
      assert Collections.list_pinned_sections(user) == []
    end
  end

  describe "control visibility" do
    test "the control is absent for a manual collection", %{conn: conn, user: user} do
      collection = manual_collection(user)

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

      refute has_element?(view, "#pin-collection")
      refute has_element?(view, "#unpin-collection")
    end

    test "the control is absent for a viewer who does not own a shared smart collection", %{
      user: owner
    } do
      collection = smart_collection(owner, %{visibility: "shared"})

      viewer = user_fixture(%{role: "admin"})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), viewer)

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

      refute has_element?(view, "#pin-collection")
      refute has_element?(view, "#unpin-collection")
    end
  end

  describe "error handling" do
    test "a forged pin attempt on a collection the viewer does not own does not crash", %{
      user: owner
    } do
      collection = smart_collection(owner, %{visibility: "shared"})

      viewer = user_fixture(%{role: "admin"})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), viewer)

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

      html = render_click(view, "pin_collection", %{})

      assert html =~ "permission"
      assert Collections.list_pinned_sections(owner) == []
    end
  end
end
