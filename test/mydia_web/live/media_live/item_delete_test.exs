defmodule MydiaWeb.MediaLive.ItemDeleteTest do
  @moduledoc """
  Deleting an item from disk removes its folder when nothing else lives in
  it (getmydia/mydia#890), and the detail page's dialog names the folders
  before the click.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Library

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    library_path = library_path_fixture(%{path: root, type: "movies"})

    %{conn: log_in_user(conn, admin_user_fixture()), root: root, library_path: library_path}
  end

  defp place_movie(library_path, rel, title) do
    item = media_item_fixture(%{type: "movie", title: title})
    absolute = Path.join(library_path.path, rel)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "video bytes")

    {:ok, _file} =
      Library.create_scanned_media_file(%{
        relative_path: rel,
        library_path_id: library_path.id,
        media_item_id: item.id,
        size: 11
      })

    item
  end

  describe "the detail page" do
    test "names the folder it will remove, then removes it", ctx do
      item =
        place_movie(
          ctx.library_path,
          "The Salt Cartographer (2019)/The Salt Cartographer (2019).mkv",
          "The Salt Cartographer"
        )

      folder = Path.join(ctx.root, "The Salt Cartographer (2019)")
      File.write!(Path.join(folder, "poster.jpg"), "art")

      {:ok, view, _html} = live(ctx.conn, "/media/#{item.id}")

      view |> element("#delete-media-button") |> render_click()
      render_async(view)

      assert has_element?(view, "#delete-preview-folder-0", "The Salt Cartographer (2019)")

      view |> element("#delete-media-confirm") |> render_click()
      {_path, flash} = assert_redirect(view)

      assert flash["info"] =~ "The Salt Cartographer deleted from disk."
      refute File.exists?(folder)
      assert File.dir?(ctx.root)
    end

    test "says which folder it will keep, keeps it, and says so after", ctx do
      item = place_movie(ctx.library_path, "Shared Reels/Reel One.mkv", "Reel One")
      place_movie(ctx.library_path, "Shared Reels/Reel Two.mkv", "Reel Two")
      folder = Path.join(ctx.root, "Shared Reels")

      {:ok, view, _html} = live(ctx.conn, "/media/#{item.id}")

      view |> element("#delete-media-button") |> render_click()
      render_async(view)

      assert has_element?(view, "#delete-preview-kept-0", "Reel Two.mkv")
      refute has_element?(view, "#delete-preview-folder-0")

      view |> element("#delete-media-confirm") |> render_click()
      {_path, flash} = assert_redirect(view)

      assert flash["info"] =~ "Kept #{folder} because it holds other media."
      assert File.exists?(Path.join(folder, "Reel Two.mkv"))
      refute File.exists?(Path.join(folder, "Reel One.mkv"))
    end

    test "choosing library-only hides the preview", ctx do
      item =
        place_movie(
          ctx.library_path,
          "The Salt Cartographer (2019)/The Salt Cartographer (2019).mkv",
          "The Salt Cartographer"
        )

      {:ok, view, _html} = live(ctx.conn, "/media/#{item.id}")

      view |> element("#delete-media-button") |> render_click()
      render_async(view)
      assert has_element?(view, "#delete-preview")

      view |> element("#delete-media-form") |> render_change(%{"delete_files" => "false"})

      refute has_element?(view, "#delete-preview")
    end
  end

  describe "the library's bulk delete" do
    test "removes a folder every selected item shared, and explains the disk option", ctx do
      one = place_movie(ctx.library_path, "Shared Reels/Reel One.mkv", "Reel One")
      two = place_movie(ctx.library_path, "Shared Reels/Reel Two.mkv", "Reel Two")

      {:ok, view, _html} = live(ctx.conn, ~p"/movies")

      render_click(view, "toggle_selection_mode", %{})
      render_click(view, "toggle_select", %{"id" => one.id})
      render_click(view, "toggle_select", %{"id" => two.id})
      render_click(view, "show_delete_confirmation", %{})

      assert has_element?(view, "#delete-confirmation-modal-disk-note")

      render_click(view, "batch_delete_confirmed", %{})

      assert view |> element("#flash-info") |> render() =~ "2 items deleted from disk."
      refute File.exists?(Path.join(ctx.root, "Shared Reels"))
    end
  end
end
