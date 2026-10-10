defmodule MydiaWeb.MediaLive.IndexAuthorizationTest do
  @moduledoc """
  The library's write handlers are reachable by every authenticated role, so
  each one has to check the role itself: the UI hiding a button does not stop
  a socket message.
  """
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @denied_flash "#flash-error"

  defp open_library(conn, user, item) do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/movies")
    render_click(view, "start_selection", %{"id" => item.id})
    view
  end

  defp monitored?(item), do: Repo.get!(MediaItem, item.id).monitored

  setup do
    %{item: media_item_fixture(%{title: "Quiet Orchard", monitored: true})}
  end

  for role <- ["readonly", "guest"] do
    describe "as #{role}" do
      setup %{conn: conn, item: item} do
        user = user_fixture(%{role: unquote(role)})
        %{view: open_library(conn, user, item)}
      end

      test "batch_unmonitor changes nothing", %{view: view, item: item} do
        render_click(view, "batch_unmonitor", %{})
        assert monitored?(item)
        assert has_element?(view, @denied_flash)
      end

      test "batch_monitor changes nothing", %{view: view, item: item} do
        Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [monitored: false])

        render_click(view, "batch_monitor", %{})
        refute monitored?(item)
        assert has_element?(view, @denied_flash)
      end

      test "toggle_item_monitored changes nothing", %{view: view, item: item} do
        render_click(view, "toggle_item_monitored", %{"id" => item.id})
        assert monitored?(item)
        assert has_element?(view, @denied_flash)
      end

      test "batch_edit_submit changes nothing", %{view: view, item: item} do
        render_click(view, "batch_edit_submit", %{"batch_edit" => %{"monitored" => "false"}})
        assert monitored?(item)
        assert has_element?(view, @denied_flash)
      end

      test "batch_reclassify is refused", %{view: view} do
        render_click(view, "batch_reclassify", %{})
        assert has_element?(view, @denied_flash)
      end

      test "batch_delete_confirmed deletes nothing", %{view: view, item: item} do
        render_click(view, "batch_delete_confirmed", %{})
        assert Repo.get(MediaItem, item.id)
        assert has_element?(view, @denied_flash)
      end

      test "trigger_rescan is refused", %{view: view} do
        render_click(view, "trigger_rescan", %{})
        assert has_element?(view, @denied_flash)
      end
    end
  end

  describe "as a user with access restrictions" do
    test "batch_reclassify leaves items outside the scope alone", %{conn: conn} do
      user = restricted_user_fixture(%{role: "user", allowed_categories: ["cartoon_movie"]})
      visible = media_item_fixture(%{title: "Lantern Harbor", type: "movie"})
      hidden = media_item_fixture(%{title: "Ember Tide", type: "movie"})

      for {item, category} <- [{visible, "cartoon_movie"}, {hidden, "anime_movie"}] do
        Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [category: category])
      end

      view = open_library(conn, user, hidden)
      render_click(view, "start_selection", %{"id" => visible.id})
      render_click(view, "batch_reclassify", %{})

      assert Repo.get!(MediaItem, hidden.id).category == "anime_movie"
      refute Repo.get!(MediaItem, visible.id).category == "cartoon_movie"
    end
  end

  describe "as a user" do
    setup %{conn: conn, item: item} do
      %{view: open_library(conn, user_fixture(%{role: "user"}), item)}
    end

    test "batch_unmonitor goes through", %{view: view, item: item} do
      render_click(view, "batch_unmonitor", %{})
      refute monitored?(item)
      refute has_element?(view, @denied_flash)
    end

    test "batch_delete_confirmed goes through", %{view: view, item: item} do
      render_click(view, "batch_delete_confirmed", %{})
      refute Repo.get(MediaItem, item.id)
    end
  end
end
