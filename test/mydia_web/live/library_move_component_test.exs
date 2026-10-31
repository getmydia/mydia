defmodule MydiaWeb.Live.LibraryMoveComponentTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :tmp_dir

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  defp library(tmp, name, type) do
    path = Path.join(tmp, name)
    File.mkdir_p!(path)

    library_path_fixture(%{
      type: type,
      path: path,
      name: name,
      auto_organize: false,
      auto_rename: false
    })
  end

  defp movie_in(library, title) do
    movie = media_item_fixture(%{type: "movie", title: title, year: 2019})
    rel = "#{title} (2019)/#{title}.mkv"
    abs = Path.join(library.path, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "xyz")

    media_file_fixture(%{
      library_path_id: library.id,
      relative_path: rel,
      size: 3,
      media_item_id: movie.id
    })

    movie
  end

  defp option(id), do: "#library-move-form option[value='#{id}']"

  # The move plan runs in the background and scans the library, which under CI
  # load outlasts render_async/1's 100ms default and leaves the preview unrendered.
  defp open(view, button) do
    view |> element(button) |> render_click()
    render_async(view, 2_000)
  end

  # Starting a move reloads the page at its own URL. Returns that URL and the
  # flash it carries. The test proxy reports the reload by itself once the
  # enqueue finishes, so this only waits for it. Calling render_async/1 here
  # races the reload: the view can exit while the proxy is still asking it for
  # its async tasks, and the proxy then dies of :noproc before it passes the
  # redirect on. The view is linked to the test, hence trap_exit.
  defp confirm(view, target) do
    Process.flag(:trap_exit, true)
    view |> form("#library-move-form", %{"target" => target.id}) |> render_submit()
    assert_redirect(view, 1_000)
  end

  setup %{tmp_dir: tmp} do
    %{
      a: library(tmp, "alpha", "movies"),
      b: library(tmp, "bravo", "movies"),
      series: library(tmp, "shows", "series")
    }
  end

  describe "from the detail page" do
    setup %{conn: conn, a: a} do
      %{conn: log_in_user(conn, admin_user_fixture()), movie: movie_in(a, "Glass Harbor")}
    end

    test "offers only the other compatible libraries", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/movies/#{ctx.movie.id}")
      refute has_element?(view, "#library-move-form")

      open(view, "#move-library-button")

      assert has_element?(view, "#library-move-form")
      assert has_element?(view, option(ctx.b.id))
      refute has_element?(view, option(ctx.a.id))
      refute has_element?(view, option(ctx.series.id))
      assert has_element?(view, "#library-move-preview")
      assert has_element?(view, "#library-move-examples li")
    end

    test "confirming enqueues the move and reloads the page with a flash", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/movies/#{ctx.movie.id}")
      open(view, "#move-library-button")

      assert {path, flash} = confirm(view, ctx.b)
      assert path == ~p"/movies/#{ctx.movie.id}"
      assert flash["info"] =~ "bravo"

      assert_enqueued(
        worker: Mydia.Jobs.LibraryMove,
        args: %{"media_item_id" => ctx.movie.id, "target_library_path_id" => ctx.b.id}
      )

      assert Repo.get!(MediaItem, ctx.movie.id).library_path_id == ctx.b.id
    end

    test "counts a file whose place in the target is taken as skipped", ctx do
      rel = "Glass Harbor (2019)/Glass Harbor.mkv"
      File.mkdir_p!(Path.join(ctx.b.path, "Glass Harbor (2019)"))
      File.write!(Path.join(ctx.b.path, rel), "the 4K one")

      media_file_fixture(%{
        library_path_id: ctx.b.id,
        relative_path: rel,
        media_item_id: ctx.movie.id
      })

      {:ok, view, _html} = live(ctx.conn, ~p"/movies/#{ctx.movie.id}")
      open(view, "#move-library-button")
      view |> form("#library-move-form", %{"target" => ctx.b.id}) |> render_change()
      render_async(view)

      assert has_element?(view, "#library-move-skipped")
    end

    test "with no other library the Move button is disabled", ctx do
      Repo.delete!(ctx.b)

      {:ok, view, _html} = live(ctx.conn, ~p"/movies/#{ctx.movie.id}")
      open(view, "#move-library-button")

      assert has_element?(view, "#library-move-empty")
      assert has_element?(view, "#library-move-confirm[disabled]")
    end
  end

  describe "from the library list" do
    test "moves every selected item", %{conn: conn, a: a, b: b} do
      first = movie_in(a, "Glass Harbor")
      second = movie_in(a, "Copper Lantern")
      conn = log_in_user(conn, admin_user_fixture())

      {:ok, view, _html} = live(conn, ~p"/movies")
      render_click(view, "start_selection", %{"id" => first.id})
      render_click(view, "start_selection", %{"id" => second.id})

      open(view, "#batch-move-library-button")
      assert has_element?(view, option(b.id))
      refute has_element?(view, "#library-move-examples")

      assert {"/movies", flash} = confirm(view, b)

      for movie <- [first, second] do
        assert_enqueued(worker: Mydia.Jobs.LibraryMove, args: %{"media_item_id" => movie.id})
      end

      assert flash["info"] =~ "2 items"
    end

    test "a selection that changes while the dialog is open closes it", ctx do
      %{conn: conn, a: a} = ctx
      first = movie_in(a, "Glass Harbor")
      second = movie_in(a, "Copper Lantern")

      {:ok, view, _html} = live(log_in_user(conn, admin_user_fixture()), ~p"/movies")
      render_click(view, "start_selection", %{"id" => first.id})
      render_click(view, "start_selection", %{"id" => second.id})
      open(view, "#batch-move-library-button")
      assert has_element?(view, "#library-move-form")

      render_click(view, "toggle_select", %{"id" => second.id})

      refute has_element?(view, "#library-move-form")
      refute_enqueued(worker: Mydia.Jobs.LibraryMove)
    end
  end

  describe "as a readonly user" do
    test "nothing is enqueued", %{conn: conn, a: a, b: b} do
      movie = movie_in(a, "Glass Harbor")
      conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

      {:ok, view, _html} = live(conn, ~p"/movies/#{movie.id}")
      open(view, "#move-library-button")
      view |> form("#library-move-form", %{"target" => b.id}) |> render_submit()

      refute_enqueued(worker: Mydia.Jobs.LibraryMove)
      assert has_element?(view, "#flash-error", "permission to move media items")
      assert Repo.get!(MediaItem, movie.id).library_path_id == nil
    end
  end
end
