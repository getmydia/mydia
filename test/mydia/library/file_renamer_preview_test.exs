defmodule Mydia.Library.FileRenamerPreviewTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.FileRenamer
  alias Mydia.Library.Structs.RenamePreview

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    library_path = library_path_fixture(%{path: tmp_dir, type: "series"})
    show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers", year: 2021})
    %{library_path: library_path, show: show, root: tmp_dir}
  end

  defp episode_file(ctx, season, episode, filename) do
    ep =
      episode_fixture(%{
        media_item_id: ctx.show.id,
        season_number: season,
        episode_number: episode
      })

    File.write!(Path.join(ctx.root, filename), "bytes")

    media_file_fixture(%{
      episode_id: ep.id,
      library_path_id: ctx.library_path.id,
      relative_path: filename
    })
  end

  test "a preview carries the episode's season and episode numbers", ctx do
    file = episode_file(ctx, 2, 5, "junk-name.mkv")

    assert %RenamePreview{season_number: 2, episode_number: 5, changed?: true} =
             FileRenamer.generate_rename_preview(file)
  end

  test "changed? is false when the file already has its proposed name", ctx do
    file = episode_file(ctx, 1, 1, "junk-name.mkv")
    preview = FileRenamer.generate_rename_preview(file)
    File.rename!(preview.current_path, preview.proposed_path)
    {:ok, file} = Library.update_media_file(file, %{relative_path: preview.proposed_filename})

    assert %RenamePreview{changed?: false} = FileRenamer.generate_rename_preview(file)
  end

  test "previews for a show come back sorted by season then episode", ctx do
    episode_file(ctx, 2, 1, "c.mkv")
    episode_file(ctx, 1, 2, "b.mkv")
    episode_file(ctx, 1, 1, "a.mkv")

    order =
      ctx.show
      |> FileRenamer.generate_rename_previews_for_media_item()
      |> Enum.map(&{&1.season_number, &1.episode_number})

    assert order == [{1, 1}, {1, 2}, {2, 1}]
  end

  test "movie previews have no season or episode" do
    movie = media_item_fixture(%{type: "movie", title: "The Paper Orchard"})
    file = media_file_fixture(%{media_item_id: movie.id})

    assert %RenamePreview{season_number: nil, episode_number: nil} =
             FileRenamer.generate_rename_preview(file)
  end
end
