defmodule Mydia.LibraryApi.RevisionTriggersTest do
  @moduledoc """
  The behavioral contract for the database-owned aggregate revision boundary.

  A `media_item_revisions` row is the latest state of one media item, ordered by a
  database-generated integer rather than a wall clock. Every assertion here pairs
  that marker with the representation a Library API consumer actually reads
  (`MediaItemView.item_map/1`, which carries `get_media_status/1`), so a trigger
  that stops covering an observable write fails on both sides at once instead of
  silently drifting.
  """

  use Mydia.DataCase, async: false

  import Ecto.Query

  alias Mydia.Downloads.Download
  alias Mydia.Downloads.History
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaFileEpisode
  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.Media
  alias Mydia.Repo
  alias Mydia.Settings
  alias MydiaWeb.LibrarySchema.MediaItemView

  defp marker!(id), do: Repo.get_by!(MediaItemRevision, media_item_id: id)

  defp assert_advanced(id, previous) do
    current = marker!(id)
    assert current.revision > previous.revision
    current
  end

  defp marker_count(id) do
    Repo.aggregate(from(r in MediaItemRevision, where: r.media_item_id == ^id), :count)
  end

  # Exactly the projection a Library API consumer receives: the item map with its
  # episodes put through `episode_map/1` too, which is where `has_file` comes
  # from. It raises rather than reporting a wrong status if a preload is missing,
  # which is the behavior the feed depends on, so reusing it here makes the
  # test's status claims the consumer's claims.
  defp view!(id) do
    item =
      id
      |> Media.get_media_item!()
      |> Repo.preload(MediaItemView.preloads())

    map = MediaItemView.item_map(item)
    %{map | episodes: Enum.map(map.episodes, &MediaItemView.episode_map/1)}
  end

  # Trash and restore move bytes, so those cases need a library path that really
  # exists on disk.
  defp library_path_with_file!(tmp_dir, type, name) do
    root = Path.join(tmp_dir, "library")
    File.mkdir_p!(root)
    File.write!(Path.join(root, name), "video bytes")
    insert(:library_path, type: type, path: root)
  end

  defp movie_file!(item, library_path, name \\ "movie.mkv") do
    {:ok, file} =
      Library.create_media_file(%{
        relative_path: name,
        library_path_id: library_path.id,
        media_item_id: item.id,
        size: byte_size("video bytes")
      })

    file
  end

  test "media item insert, update, and delete leave monotonic live/tombstone markers" do
    item = insert(:media_item, title: "Before")
    inserted = marker!(item.id)
    refute inserted.deleted

    {:ok, _} = Mydia.Media.update_media_item(item, %{title: "After"})
    updated = assert_advanced(item.id, inserted)
    refute updated.deleted

    {:ok, _deleted, _files_not_deleted} = Mydia.Media.delete_media_item(item)
    tombstone = assert_advanced(item.id, updated)
    assert tombstone.deleted
  end

  test "a rolled-back write does not advance the marker" do
    item = insert(:media_item)
    before = marker!(item.id)

    assert {:error, :forced} =
             Repo.transaction(fn ->
               Repo.update!(Ecto.Changeset.change(item, title: "Rolled back"))

               # The trigger must have fired inside the transaction, or this
               # test would pass with the trigger deleted entirely: it is the
               # rollback undoing a real allocation that is under test.
               in_transaction = marker!(item.id)
               assert in_transaction.revision > before.revision

               Repo.rollback(:forced)
             end)

    assert marker!(item.id).revision == before.revision
  end

  test "a sweep-only parent write advances the marker by design" do
    # `stamp_seasons_refreshed/1` writes only a refresh watermark that
    # `MediaItemView.item_map/1` never reads, so it is a false-positive
    # delivery. The parent trigger is unconditional on purpose: the design spec
    # says `media_items` "insert and every update are observable", and a missed
    # consumer-visible change is worse than a redundant re-delivery. Narrowing
    # the trigger to a column list must first change that spec, and this test is
    # what makes the narrowing fail loudly.
    item = insert(:media_item)
    before = marker!(item.id)

    assert {1, _} = Mydia.Media.stamp_seasons_refreshed(item)

    swept = assert_advanced(item.id, before)
    refute swept.deleted
    assert marker_count(item.id) == 1
  end

  test "episode monitored, title and air_date changes advance the owning show" do
    show = insert(:tv_show)
    episode = insert(:episode, media_item: show, monitored: true)

    listed = marker!(show.id)
    assert [%{monitored: true, has_file: false}] = view!(show.id).episodes
    assert view!(show.id).status.state == :missing

    {:ok, _} = Media.update_episode(episode, %{monitored: false})
    after_monitored = assert_advanced(show.id, listed)
    assert [%{monitored: false}] = view!(show.id).episodes
    refute view!(show.id).status.monitored

    {:ok, _} = Media.update_episode(episode, %{title: "Renamed"})
    after_title = assert_advanced(show.id, after_monitored)
    assert [%{title: "Renamed"}] = view!(show.id).episodes

    {:ok, _} = Media.update_episode(episode, %{air_date: ~D[2099-01-01]})
    after_air_date = assert_advanced(show.id, after_title)
    assert [%{air_date: ~D[2099-01-01]}] = view!(show.id).episodes
    assert view!(show.id).status.state == :upcoming

    refute after_air_date.deleted
    assert marker_count(show.id) == 1
  end

  @tag :tmp_dir
  test "media file insert, trash, restore, extra transition and delete advance the owner",
       %{tmp_dir: tmp_dir} do
    item = insert(:media_item)
    library_path = library_path_with_file!(tmp_dir, :movies, "movie.mkv")

    listed = marker!(item.id)
    file = movie_file!(item, library_path)
    after_insert = assert_advanced(item.id, listed)
    assert view!(item.id).status.state == :downloaded
    assert view!(item.id).status.file_count == 1

    {:ok, _trashed} = Library.trash_media_file(Repo.preload(file, :library_path))
    after_trash = assert_advanced(item.id, after_insert)
    assert view!(item.id).status.state == :missing

    {:ok, _restored} =
      file |> Repo.reload!() |> Repo.preload(:library_path) |> Library.restore_media_file()

    after_restore = assert_advanced(item.id, after_trash)
    assert view!(item.id).status.state == :downloaded

    {:ok, _extra} = Library.update_media_file(Repo.reload!(file), %{extra_kind: :trailer})
    after_extra = assert_advanced(item.id, after_restore)
    assert view!(item.id).status.file_count == 0
    assert view!(item.id).status.state == :missing

    {:ok, _deleted} = Library.delete_media_file(Repo.reload!(file))
    _after_delete = assert_advanced(item.id, after_extra)
    assert marker_count(item.id) == 1
  end

  test "removing a media_file_episodes link and re-linking it advance the owner" do
    show = insert(:tv_show)
    episode = insert(:episode, media_item: show)
    library_path = insert(:library_path, type: :series)

    {:ok, file} =
      Library.create_media_file(%{
        relative_path: "episode.mkv",
        library_path_id: library_path.id,
        episode_id: episode.id,
        size: byte_size("video bytes")
      })

    listed = marker!(show.id)

    # `Episode.hasFile` reads the join table, so an unlinked file makes the
    # episode read as missing even though `media_files.episode_id` is untouched.
    assert {1, _} =
             Repo.delete_all(
               from(link in MediaFileEpisode, where: link.media_file_id == ^file.id)
             )

    after_removal = assert_advanced(show.id, listed)
    assert view!(show.id).episodes |> hd() |> Map.fetch!(:has_file) == false

    {:ok, _} = Library.ensure_episode_link(file)
    _after_link = assert_advanced(show.id, after_removal)
    assert view!(show.id).episodes |> hd() |> Map.fetch!(:has_file)
  end

  test "download insertion, completion, failure and deletion advance the owning item" do
    item = insert(:media_item)
    listed = marker!(item.id)

    {:ok, download} = History.create_download(%{media_item_id: item.id, title: "Fetch"})
    after_insert = assert_advanced(item.id, listed)
    assert view!(item.id).status.state == :downloading

    {:ok, completed} = History.mark_download_completed(download)
    after_completion = assert_advanced(item.id, after_insert)
    assert view!(item.id).status.state == :missing

    {:ok, failed} = History.mark_download_failed(completed, "client refused")
    after_failure = assert_advanced(item.id, after_completion)
    assert view!(item.id).status.state == :missing

    {:ok, _deleted} = History.delete_download(failed)
    _after_delete = assert_advanced(item.id, after_failure)
    assert marker_count(item.id) == 1
  end

  test "an episode, file and download re-parenting each advance both owners" do
    library_path = insert(:library_path, type: :series)

    # An episode moving to another show is observable on both shows.
    episode_old = insert(:tv_show)
    episode_new = insert(:tv_show)
    episode = insert(:episode, media_item: episode_old)
    episode_before = {marker!(episode_old.id), marker!(episode_new.id)}

    {:ok, _moved_episode} = Media.update_episode(episode, %{media_item_id: episode_new.id})

    assert_advanced(episode_old.id, elem(episode_before, 0))
    assert_advanced(episode_new.id, elem(episode_before, 1))

    # A file's owner moves with its episode's media item, and the file itself
    # can be re-parented directly.
    file_old = episode_new
    file_new = insert(:tv_show)

    {:ok, file} =
      Library.create_media_file(%{
        relative_path: "episode.mkv",
        library_path_id: library_path.id,
        episode_id: episode.id,
        size: byte_size("video bytes")
      })

    file_before = {marker!(file_old.id), marker!(file_new.id)}

    {:ok, _moved_file} =
      Library.update_media_file(Repo.reload!(file), %{episode_id: nil, media_item_id: file_new.id})

    assert_advanced(file_old.id, elem(file_before, 0))
    assert_advanced(file_new.id, elem(file_before, 1))

    download_old = insert(:media_item)
    download_new = insert(:media_item)
    {:ok, download} = History.create_download(%{media_item_id: download_old.id, title: "Fetch"})
    download_before = {marker!(download_old.id), marker!(download_new.id)}

    {:ok, _moved_download} = History.update_download(download, %{media_item_id: download_new.id})

    assert_advanced(download_old.id, elem(download_before, 0))
    assert_advanced(download_new.id, elem(download_before, 1))
  end

  test "a quality profile rename advances every referencing media item" do
    profile = insert(:quality_profile, quality_standards: %{preferred_resolutions: ["1080p"]})
    first = insert(:media_item, quality_profile: profile)
    second = insert(:media_item, quality_profile: profile)
    untouched = insert(:media_item)

    before = %{
      first: marker!(first.id),
      second: marker!(second.id),
      untouched: marker!(untouched.id)
    }

    {:ok, _renamed} = Settings.update_quality_profile(profile, %{name: "Renamed Profile"})

    after_rename = %{
      first: assert_advanced(first.id, before.first),
      second: assert_advanced(second.id, before.second),
      untouched: marker!(untouched.id)
    }

    assert view!(first.id).quality_profile.name == "Renamed Profile"
    assert view!(second.id).quality_profile.name == "Renamed Profile"

    # Deleting a profile unassigns it, which is itself a media_items write, and
    # then removes the row: both have to leave the items' markers live.
    {:ok, _deleted} = Settings.force_delete_quality_profile(Repo.reload!(profile))

    assert_advanced(first.id, after_rename.first)
    _ = assert_advanced(second.id, after_rename.second)
    assert marker!(untouched.id).revision == before.untouched.revision
  end

  test "writes that cannot change the representation do not advance the marker" do
    item = insert(:media_item)
    library_path = insert(:library_path, type: :movies)
    file = movie_file!(item, library_path)
    {:ok, download} = History.create_download(%{media_item_id: item.id, title: "Progress"})

    listed = marker!(item.id)

    assert {1, _} =
             Repo.update_all(
               from(f in MediaFile, where: f.id == ^file.id),
               set: [analysis_attempts: 7]
             )

    assert {1, _} =
             Repo.update_all(
               from(d in Download, where: d.id == ^download.id),
               set: [bytes_pulled: 4_194_304]
             )

    assert marker!(item.id).revision == listed.revision
    assert marker_count(item.id) == 1
  end

  test "parent deletion leaves a tombstone the cascading child deletes cannot resurrect" do
    show = insert(:tv_show)
    episode = insert(:episode, media_item: show)
    library_path = insert(:library_path, type: :series)

    {:ok, file} =
      Library.create_media_file(%{
        relative_path: "show.mkv",
        library_path_id: library_path.id,
        media_item_id: show.id,
        size: byte_size("video bytes")
      })

    {:ok, download} =
      History.create_download(%{media_item_id: show.id, episode_id: episode.id, title: "Fetch"})

    listed = marker!(show.id)

    {:ok, _deleted, 0} = Media.delete_media_item(show)

    tombstone = assert_advanced(show.id, listed)
    assert tombstone.deleted

    refute Repo.get(Mydia.Media.Episode, episode.id)
    refute Repo.get(MediaFile, file.id)
    refute Repo.get(Download, download.id)

    # A cascade that marked an owner it could still see would flip this back to
    # a live marker; the trigger's join through `media_items` is what prevents it.
    assert marker!(show.id).deleted
    assert marker_count(show.id) == 1
  end

  test "several parent and child writes leave one marker carrying the greatest revision" do
    show = insert(:tv_show)
    episode = insert(:episode, media_item: show)
    library_path = insert(:library_path, type: :series)

    {:ok, _file} =
      Library.create_media_file(%{
        relative_path: "episode.mkv",
        library_path_id: library_path.id,
        episode_id: episode.id,
        size: byte_size("video bytes")
      })

    {:ok, download} = History.create_download(%{episode_id: episode.id, title: "Fetch"})

    {:ok, _} = Media.update_episode(episode, %{monitored: false})
    after_episode = marker!(show.id).revision

    {:ok, _} = Media.update_media_item(show, %{title: "Renamed Show"})
    after_show = marker!(show.id).revision

    {:ok, _} = History.mark_download_failed(download, "nope")
    after_download = marker!(show.id).revision

    assert marker_count(show.id) == 1

    final = marker!(show.id)
    assert final.revision == Enum.max([after_episode, after_show, after_download])
    refute final.deleted
    assert view!(show.id).title == "Renamed Show"
  end
end
