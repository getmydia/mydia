defmodule MydiaWeb.MediaLive.FileDeleteTest do
  @moduledoc """
  Deleting a file by hand used to be the one deletion with no undo: the
  automation soft-deleted through the trash while a human's click ran
  Repo.delete plus File.rm. Trash is now the default here too.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Library
  alias Mydia.Repo

  # Mirrors test/mydia_web/live/admin_trash_live_test.exs, which mirrors
  # test/mydia_web/live/admin_duplicates_live_test.exs: the canonical
  # authenticated LiveView setup in this project. There is no `sign_in/2`
  # helper in the repo; session plus the bearer header is what actually
  # authenticates against the `:require_authenticated` pipeline.
  setup %{conn: conn, tmp_dir: tmp_dir} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    trash_root = Path.join(tmp_dir, "trash")
    File.mkdir_p!(trash_root)
    Application.put_env(:mydia, :trash_dir, trash_root)
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    library_path = library_path_fixture(%{path: root, type: "movies"})
    item = media_item_fixture(%{type: "movie", title: "The Salt Cartographer"})

    File.write!(Path.join(root, "film.mkv"), "video bytes")

    {:ok, file} =
      Library.create_scanned_media_file(%{
        relative_path: "film.mkv",
        library_path_id: library_path.id,
        media_item_id: item.id,
        size: 11
      })

    %{conn: conn, item: item, media_file: file, root: root}
  end

  @tag :tmp_dir
  test "defaults to moving the file to trash", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, "/media/#{ctx.item.id}")

    view |> element("#file-delete-#{ctx.media_file.id}") |> render_click()
    view |> element("#file-delete-confirm") |> render_click()

    reloaded = Repo.reload(ctx.media_file)
    refute is_nil(reloaded.trashed_at)
    assert reloaded.trashed_reason == :manual
    refute File.exists?(Path.join(ctx.root, "film.mkv"))
  end

  @tag :tmp_dir
  test "permanent still hard-deletes", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, "/media/#{ctx.item.id}")

    view |> element("#file-delete-#{ctx.media_file.id}") |> render_click()

    view
    |> form("#file-delete-form", %{"file_delete_mode" => "permanent"})
    |> render_change()

    view |> element("#file-delete-confirm") |> render_click()

    assert is_nil(Repo.get(Mydia.Library.MediaFile, ctx.media_file.id))
    refute File.exists?(Path.join(ctx.root, "film.mkv"))
  end

  @tag :tmp_dir
  test "library-only leaves the file on disk", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, "/media/#{ctx.item.id}")

    view |> element("#file-delete-#{ctx.media_file.id}") |> render_click()

    view
    |> form("#file-delete-form", %{"file_delete_mode" => "library_only"})
    |> render_change()

    view |> element("#file-delete-confirm") |> render_click()

    assert is_nil(Repo.get(Mydia.Library.MediaFile, ctx.media_file.id))
    assert File.exists?(Path.join(ctx.root, "film.mkv"))
  end
end
