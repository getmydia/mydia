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

      view |> element("#move-library-button") |> render_click()

      assert has_element?(view, "#library-move-form")
      assert has_element?(view, option(ctx.b.id))
      refute has_element?(view, option(ctx.a.id))
      refute has_element?(view, option(ctx.series.id))
      assert has_element?(view, "#library-move-preview")
      assert has_element?(view, "#library-move-examples li")
    end

    test "confirming enqueues the move and sets a flash", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/movies/#{ctx.movie.id}")
      view |> element("#move-library-button") |> render_click()

      view |> form("#library-move-form", %{"target" => ctx.b.id}) |> render_submit()

      assert_enqueued(
        worker: Mydia.Jobs.LibraryMove,
        args: %{"media_item_id" => ctx.movie.id, "target_library_path_id" => ctx.b.id}
      )

      assert has_element?(view, "#flash-info")
      refute has_element?(view, "#library-move-form")
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
      view |> element("#move-library-button") |> render_click()
      view |> form("#library-move-form", %{"target" => ctx.b.id}) |> render_change()

      assert has_element?(view, "#library-move-skipped")
    end

    test "with no other library the Move button is disabled", ctx do
      Repo.delete!(ctx.b)

      {:ok, view, _html} = live(ctx.conn, ~p"/movies/#{ctx.movie.id}")
      view |> element("#move-library-button") |> render_click()

      assert has_element?(view, "#library-move-empty")
      assert has_element?(view, "#library-move-confirm[disabled]")
    end
  end

  describe "from the library list" do
    test "moves every selected item", %{conn: conn, a: a, b: b} do
      first = movie_in(a, "Glass Harbor")
      second = movie_in(a, "Copper Lantern")

      {:ok, view, _html} = live(log_in_user(conn, admin_user_fixture()), ~p"/movies")
      render_click(view, "start_selection", %{"id" => first.id})
      render_click(view, "start_selection", %{"id" => second.id})

      view |> element("#batch-move-library-button") |> render_click()
      assert has_element?(view, option(b.id))
      refute has_element?(view, "#library-move-examples")

      view |> form("#library-move-form", %{"target" => b.id}) |> render_submit()

      for movie <- [first, second] do
        assert_enqueued(worker: Mydia.Jobs.LibraryMove, args: %{"media_item_id" => movie.id})
      end

      assert has_element?(view, "#flash-info")
    end
  end

  describe "as a readonly user" do
    test "nothing is enqueued", %{conn: conn, a: a, b: b} do
      movie = movie_in(a, "Glass Harbor")
      conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

      {:ok, view, _html} = live(conn, ~p"/movies/#{movie.id}")
      view |> element("#move-library-button") |> render_click()
      view |> form("#library-move-form", %{"target" => b.id}) |> render_submit()

      refute_enqueued(worker: Mydia.Jobs.LibraryMove)
      assert has_element?(view, "#flash-error", "permission to move media items")
      assert Repo.get!(MediaItem, movie.id).library_path_id == nil
    end
  end
end
