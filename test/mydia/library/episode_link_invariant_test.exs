defmodule Mydia.Library.EpisodeLinkInvariantTest do
  @moduledoc """
  Every writer that puts an `episode_id` on a media file must also record the
  link in `media_file_episodes`.

  `Episode.media_files` is a `many_to_many` through that join table, which is
  what lets a `S01E09E10` file belong to both of its episodes. The cost of that
  design is this invariant: a row with an `episode_id` but no join row is
  invisible on the episode page. That is a worse bug than the one the join
  table fixes, so it is guarded rather than left to review.

  Two checks, because neither alone is sufficient:

    * The behavioural check proves the funnels in `Mydia.Library` maintain the
      link. It cannot see a module that bypasses them.
    * The source check catches exactly that bypass: a direct
      `MediaFile.changeset(...) |> Repo.insert()` in a module that never calls
      `ensure_episode_link/1`.
  """
  use Mydia.DataCase, async: true

  import Mydia.Factory

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  describe "the Library write funnels" do
    setup do
      show = insert(:tv_show, %{title: "Fathom Rift", year: 2015})
      episode = insert(:episode, %{media_item: show, season_number: 2, episode_number: 3})
      library_path = insert(:library_path, %{type: :series})

      {:ok, show: show, episode: episode, library_path: library_path}
    end

    test "create_media_file/1 links the episode", %{
      episode: episode,
      library_path: library_path
    } do
      {:ok, _file} =
        Library.create_media_file(%{
          episode_id: episode.id,
          library_path_id: library_path.id,
          relative_path: "Fathom Rift S02E03.mkv",
          path: "/series/Fathom Rift S02E03.mkv",
          size: 1_000
        })

      assert [%MediaFile{}] = Repo.preload(episode, :media_files).media_files
    end

    test "update_media_file/2 links an episode attached after creation", %{
      episode: episode,
      library_path: library_path,
      show: show
    } do
      {:ok, file} =
        Library.create_media_file(%{
          media_item_id: show.id,
          library_path_id: library_path.id,
          relative_path: "Fathom Rift S02E03 unmatched.mkv",
          path: "/series/Fathom Rift S02E03 unmatched.mkv",
          size: 1_000
        })

      assert [] = Repo.preload(episode, :media_files).media_files

      {:ok, _} = Library.update_media_file(file, %{media_item_id: nil, episode_id: episode.id})

      assert [%MediaFile{}] = Repo.preload(episode, :media_files).media_files
    end
  end

  describe "modules that insert media files directly" do
    # Modules allowed to build a MediaFile changeset without calling
    # ensure_episode_link: they either never set an episode_id, or they are the
    # linker itself.
    @exempt [
      # The funnels live here and maintain the link themselves.
      "lib/mydia/library.ex",
      # Classifies extras; never assigns an episode.
      "lib/mydia/jobs/extra_classification.ex"
    ]

    test "each one also calls ensure_episode_link/1" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&(&1 in @exempt))
        |> Enum.filter(fn path ->
          source = File.read!(path)

          builds_media_file? =
            String.contains?(source, "MediaFile.changeset") and
              String.contains?(source, "Repo.insert")

          builds_media_file? and not String.contains?(source, "ensure_episode_link")
        end)

      assert offenders == [],
             """
             These modules insert a media file without recording the episode link:

             #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

             A media file whose episode_id has no media_file_episodes row does
             not appear on the episode page at all, because Episode.media_files
             reads through that join table.

             Call Mydia.Library.ensure_episode_link/1 after the insert, or add
             the module to @exempt if it never assigns an episode_id.
             """
    end
  end
end
