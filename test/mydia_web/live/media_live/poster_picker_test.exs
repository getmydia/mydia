defmodule MydiaWeb.MediaLive.PosterPickerTest do
  @moduledoc """
  The poster picker on the media detail page.

  Changes the global `:generated_media_path` and `:metadata_relay_url` env, so
  it cannot run async.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Media.PosterStore
  alias Mydia.Repo

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::64>>
  @jpg <<0xFF, 0xD8, 0xFF, 0xE0, 0::64>>

  setup do
    base = Path.join(System.tmp_dir!(), "poster_picker_#{System.unique_integer([:positive])}")
    store = Path.join(base, "store")
    root = Path.join(base, "library")
    File.mkdir_p!(store)
    File.mkdir_p!(root)

    previous = Application.fetch_env(:mydia, :generated_media_path)
    Application.put_env(:mydia, :generated_media_path, store)
    File.mkdir_p!(PosterStore.storage_dir())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mydia, :generated_media_path, value)
        :error -> Application.delete_env(:mydia, :generated_media_path)
      end

      File.rm_rf!(base)
    end)

    %{root: root}
  end

  defp admin_conn(conn), do: log_in_user(conn, create_admin_user())

  # A movie with a TMDB id, its detail-page lookups warmed so mounting asks
  # the relay for nothing but the images the picker fetches.
  defp tmdb_movie do
    tmdb_id = unique_provider_id()
    warm_recommendations_cache(tmdb_id, :movie, [])
    warm_movie_details_cache(tmdb_id)
    media_item_fixture(%{type: "movie", title: "Copper Lantern", tmdb_id: tmdb_id})
  end

  defp stub_images(bypass, tmdb_id, status, posters) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}/images", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        status,
        Jason.encode!(%{"posters" => posters, "backdrops" => [], "logos" => []})
      )
    end)
  end

  defp open_picker(view) do
    view |> element("#poster-edit-button") |> render_click()
    render_async(view)
    assert has_element?(view, "#poster-picker")
    view
  end

  test "the pencil shows only for users who can update media", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    assert has_element?(view, "#poster-edit-button")

    readonly = user_fixture(%{role: "readonly"})
    {:ok, view, _html} = live(log_in_user(build_conn(), readonly), ~p"/media/#{item.id}")
    refute has_element?(view, "#poster-edit-button")

    render_click(view, "open_poster_picker", %{})
    refute has_element?(view, "#poster-picker")
  end

  test "browse lists relay posters and saving one sets the override", %{conn: conn} do
    item = tmdb_movie()
    bypass = point_relay_at_bypass()

    stub_images(bypass, item.tmdb_id, 200, [
      %{"file_path" => "/first.jpg", "iso_639_1" => "en", "vote_average" => 5.0},
      %{"file_path" => "/second.jpg", "iso_639_1" => "fr", "vote_average" => 3.0}
    ])

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    open_picker(view)

    assert has_element?(view, "#poster-option-0", "en")
    assert has_element?(view, "#poster-option-1", "fr")

    view |> element("#poster-option-1") |> render_click()
    view |> element("#poster-save") |> render_click()

    assert Repo.reload!(item).poster_override == "/second.jpg"
    refute has_element?(view, "#poster-picker")
  end

  test "browse puts the best rated first, unrated last", %{conn: conn} do
    item = tmdb_movie()
    bypass = point_relay_at_bypass()

    stub_images(bypass, item.tmdb_id, 200, [
      %{"file_path" => "/unrated.jpg", "iso_639_1" => nil, "vote_average" => nil},
      %{"file_path" => "/low.jpg", "iso_639_1" => "en", "vote_average" => 1.0},
      %{"file_path" => "/high.jpg", "iso_639_1" => "en", "vote_average" => 9.0}
    ])

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    open_picker(view)

    view |> element("#poster-option-0") |> render_click()
    view |> element("#poster-save") |> render_click()

    assert Repo.reload!(item).poster_override == "/high.jpg"
  end

  test "a relay failure shows the error and the upload tab still works", %{conn: conn} do
    item = tmdb_movie()
    bypass = point_relay_at_bypass()
    stub_images(bypass, item.tmdb_id, 500, [])

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    open_picker(view)

    assert has_element?(view, "#poster-browse-error")

    view |> element("#poster-tab-upload") |> render_click()
    assert has_element?(view, "#poster-upload-form")
  end

  test "uploading a PNG sets a hosted override", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    open_picker(view)
    view |> element("#poster-tab-upload") |> render_click()

    upload =
      file_input(view, "#poster-upload-form", :poster, [
        %{name: "mine.png", content: @png, type: "image/png"}
      ])

    render_upload(upload, "mine.png")
    view |> element("#poster-save") |> render_click()

    assert Repo.reload!(item).poster_override =~ ~r{^/generated/posters/}
  end

  test "an upload that is not really an image shows an error and saves nothing",
       %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    open_picker(view)
    view |> element("#poster-tab-upload") |> render_click()

    upload =
      file_input(view, "#poster-upload-form", :poster, [
        %{name: "fake.jpg", content: "<html>nope</html>", type: "image/jpeg"}
      ])

    render_upload(upload, "fake.jpg")
    view |> element("#poster-save") |> render_click()

    assert has_element?(view, "#poster-save-error")
    assert Repo.reload!(item).poster_override == nil
  end

  test "the folder tab lists candidates and selecting one saves it", %{conn: conn, root: root} do
    dir = "Copper Lantern (2001)"
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join([root, dir, "film.mkv"]), "video")
    File.write!(Path.join([root, dir, "poster.jpg"]), @jpg)

    lp = library_path_fixture(%{path: root, type: "movies"})
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})

    media_file_fixture(%{
      media_item_id: item.id,
      library_path_id: lp.id,
      relative_path: "#{dir}/film.mkv"
    })

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    open_picker(view)

    view |> element("#poster-tab-folder") |> render_click()
    assert has_element?(view, "#poster-candidate-0", "poster.jpg")

    view |> element("#poster-candidate-0") |> render_click()
    view |> element("#poster-save") |> render_click()

    assert Repo.reload!(item).poster_override =~ ~r{^/generated/posters/}
  end

  test "a non-admin editor sees folder thumbnails served by the candidate route",
       %{conn: conn, root: root} do
    dir = "Copper Lantern (2001)"
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join([root, dir, "film.mkv"]), "video")
    File.write!(Path.join([root, dir, "poster.jpg"]), @jpg)

    lp = library_path_fixture(%{path: root, type: "movies"})
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})

    media_file_fixture(%{
      media_item_id: item.id,
      library_path_id: lp.id,
      relative_path: "#{dir}/film.mkv"
    })

    editor = log_in_user(conn, user_fixture(%{role: "user"}))
    {:ok, view, _html} = live(editor, ~p"/media/#{item.id}")
    open_picker(view)
    view |> element("#poster-tab-folder") |> render_click()

    src = "/media/#{item.id}/poster-candidates/#{lp.id}/"
    assert has_element?(view, "#poster-candidate-0 img[src^='#{src}']")
  end

  test "out-of-range and non-integer indexes select and save nothing",
       %{conn: conn, root: root} do
    item = tmdb_movie()
    bypass = point_relay_at_bypass()
    stub_images(bypass, item.tmdb_id, 200, [%{"file_path" => "/only.jpg", "iso_639_1" => "en"}])

    dir = "Copper Lantern (2001)"
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join([root, dir, "film.mkv"]), "video")
    File.write!(Path.join([root, dir, "poster.jpg"]), @jpg)
    lp = library_path_fixture(%{path: root, type: "movies"})

    media_file_fixture(%{
      media_item_id: item.id,
      library_path_id: lp.id,
      relative_path: "#{dir}/film.mkv"
    })

    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")
    open_picker(view)

    for index <- ["99", "x", "-1"] do
      view |> element("#poster-option-0") |> render_click(%{"index" => index})
      refute has_element?(view, "#poster-option-0[aria-pressed='true']")
      assert has_element?(view, "#poster-save[disabled]")
    end

    view |> element("#poster-tab-folder") |> render_click()

    for index <- ["99", "x", "-1"] do
      view |> element("#poster-candidate-0") |> render_click(%{"index" => index})
      refute has_element?(view, "#poster-candidate-0[aria-pressed='true']")
      assert has_element?(view, "#poster-save[disabled]")
    end

    assert has_element?(view, "#poster-picker")
    assert Repo.reload!(item).poster_override == nil
  end

  test "Escape and the backdrop close the picker", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})
    {:ok, view, _html} = live(admin_conn(conn), ~p"/media/#{item.id}")

    open_picker(view)
    view |> element("#poster-picker") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#poster-picker")

    open_picker(view)
    view |> element("#poster-picker-backdrop") |> render_click()
    refute has_element?(view, "#poster-picker")
  end

  test "another open detail page of the item shows the new poster", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})
    admin = create_admin_user()

    {:ok, other, _html} = live(log_in_user(conn, admin), ~p"/media/#{item.id}")
    refute has_element?(other, "#media-poster[src*='elsewhere.jpg']")

    {:ok, _} =
      Mydia.Media.Posters.set_provider_poster(
        Mydia.Accounts.Scope.for_user(admin),
        item,
        "/elsewhere.jpg"
      )

    assert has_element?(other, "#media-poster[src*='elsewhere.jpg']")
  end

  test "reset is offered only with an override, and clears it", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})
    conn = admin_conn(conn)

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
    open_picker(view)
    refute has_element?(view, "#poster-reset")

    item
    |> MediaItem.poster_override_changeset(%{poster_override: "/chosen.jpg"})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
    open_picker(view)

    view |> element("#poster-reset") |> render_click()
    assert Repo.reload!(item).poster_override == nil
  end
end
