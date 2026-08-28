defmodule MydiaWeb.MediaLive.ShowExtrasTest do
  # Connected LiveView tests cannot be async under the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  defp insert_file(item, library_path, name, overrides) do
    attrs =
      Enum.into(overrides, %{
        media_item_id: item.id,
        library_path_id: library_path.id,
        relative_path: "Ratatouille (2007)/#{name}"
      })

    %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert!()
  end

  setup do
    library_path = library_path_fixture(%{type: "movies"})
    item = media_item_fixture(%{type: "movie", title: "Ratatouille"})

    feature = insert_file(item, library_path, "Ratatouille.2007.1080p.mkv", %{})

    extra =
      insert_file(item, library_path, "Chez Gusteau_new.mkv", %{
        extra_kind: :other,
        extra_source: :duration
      })

    %{item: item, feature: feature, extra: extra}
  end

  test "renders extras separately from versions", %{
    conn: conn,
    item: item,
    feature: feature,
    extra: extra
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    assert has_element?(view, "#media-files-section")
    assert has_element?(view, "#extras-disclosure")
    assert has_element?(view, "#version-#{feature.id}")
    assert has_element?(view, "#extra-#{extra.id}")
    refute has_element?(view, "#version-#{extra.id}")
  end

  test "promoting an extra makes it a version", %{conn: conn, item: item, extra: extra} do
    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view |> element("#promote-#{extra.id}") |> render_click()

    reloaded = Repo.reload!(extra)
    assert reloaded.extra_kind == nil
    assert reloaded.extra_source == :operator

    assert has_element?(view, "#version-#{extra.id}")
    refute has_element?(view, "#extra-#{extra.id}")
  end

  test "demoting a version makes it an extra", %{conn: conn, item: item, feature: feature} do
    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view |> element("#demote-#{feature.id}") |> render_click()

    reloaded = Repo.reload!(feature)
    assert reloaded.extra_kind == :other
    assert reloaded.extra_source == :operator

    assert has_element?(view, "#extra-#{feature.id}")
  end
end
