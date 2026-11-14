defmodule Mydia.Downloads.WantedFilesTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Downloads.{FileSelection, WantedFiles}
  alias Mydia.Indexers.Structs.SearchResultMetadata

  @pack "The.Lantern.Keepers.S02"

  setup do
    show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers"})

    eps =
      for n <- 1..10 do
        episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: n})
      end

    for ep <- Enum.take(eps, 4), do: media_file_fixture(%{episode_id: ep.id})

    %{show: show, eps: eps, ids: Enum.map(eps, & &1.id)}
  end

  defp ep_file(i, n, ext \\ "mkv") do
    num = n |> Integer.to_string() |> String.pad_leading(2, "0")
    file("#{@pack}/#{@pack}E#{num}.1080p.#{ext}", i)
  end

  defp file(path, i), do: %{index: i, path: path, length: 100}

  defp pack_files, do: Enum.map(1..10, &ep_file(&1 - 1, &1))

  defp ctx(show, ids), do: %{media_item: show, season_number: 2, targeted_episode_ids: ids}

  test "owned episodes are skipped", %{show: show, ids: ids} do
    sel = WantedFiles.select(ctx(show, Enum.drop(ids, 4)), pack_files())
    assert sel.only_files == [4, 5, 6, 7, 8, 9]
    assert sel.skipped_owned_episode_ids |> Enum.sort() == Enum.take(ids, 4) |> Enum.sort()
    assert sel.file_episodes == Map.new(4..9, &{&1, Enum.at(ids, &1)})
    assert sel.selected_bytes == 600
  end

  test "targeted but owned episode is kept", %{show: show, ids: ids} do
    sel = WantedFiles.select(ctx(show, [Enum.at(ids, 2) | Enum.drop(ids, 4)]), pack_files())
    assert sel.only_files == [2, 4, 5, 6, 7, 8, 9]
  end

  test "subtitles follow their video", %{show: show, ids: ids} do
    files = [
      file("#{@pack}/#{@pack}E01.en.srt", 0),
      file("#{@pack}/#{@pack}E05.en.srt", 1),
      ep_file(2, 5)
    ]

    sel = WantedFiles.select(ctx(show, Enum.drop(ids, 4)), files)
    assert sel.only_files == [1, 2]
    assert sel.file_episodes == %{2 => Enum.at(ids, 4)}
  end

  test "single-episode grabs keep every video, even owned untargeted ones", %{
    show: show,
    ids: ids
  } do
    ctx = %{ctx(show, [Enum.at(ids, 4)]) | targeted_episode_ids: [Enum.at(ids, 4)]}
    ctx = Map.put(ctx, :single_episode?, true)

    sel = WantedFiles.select(ctx, [ep_file(0, 5), ep_file(1, 1)])
    assert sel.only_files == nil
    assert sel.skipped_owned_episode_ids == []

    sel = WantedFiles.select(ctx, [ep_file(0, 5), ep_file(1, 1), file("Sample/s02e05.mkv", 2)])
    assert sel.only_files == [0, 1]
  end

  test "samples, extras and junk are dropped", %{show: show, ids: ids} do
    files = [
      ep_file(0, 5),
      file("#{@pack}/Sample/s02e05.mkv", 1),
      file("#{@pack}/Featurettes/x.mkv", 2),
      file("#{@pack}/info.nfo", 3),
      file("#{@pack}/cover.jpg", 4)
    ]

    sel = WantedFiles.select(ctx(show, Enum.drop(ids, 4)), files)
    assert sel.only_files == [0]
  end

  test "unmatched files are kept", %{show: show, ids: ids} do
    files = [ep_file(0, 1), ep_file(1, 5), file("#{@pack}/bonus_unlabeled.mkv", 2)]
    sel = WantedFiles.select(ctx(show, Enum.drop(ids, 4)), files)
    assert sel.only_files == [1, 2]
    assert sel.file_episodes == %{1 => Enum.at(ids, 4)}
  end

  test "multi-episode files are kept and unmapped", %{show: show, ids: ids} do
    files = [ep_file(0, 1), file("#{@pack}/#{@pack}E05E06.mkv", 1)]
    sel = WantedFiles.select(ctx(show, Enum.drop(ids, 4)), files)
    assert sel.only_files == [1]
    assert sel.file_episodes == %{}
  end

  test "keeps everything when every video would be dropped", %{show: show} do
    files = Enum.map(1..4, &ep_file(&1 - 1, &1))
    sel = WantedFiles.select(ctx(show, []), files)
    assert sel.only_files == nil
    assert sel.selected_bytes == 400
  end

  test "keeps everything when nothing is dropped", %{show: show, ids: ids} do
    files = Enum.map(5..10, &ep_file(&1 - 5, &1))
    sel = WantedFiles.select(ctx(show, ids), files)
    assert sel.only_files == nil
    assert sel.selected_bytes == 600
    assert map_size(sel.file_episodes) == 6
  end

  test "movies keep only the movie file" do
    movie = media_item_fixture(%{type: "movie"})

    files = [
      file("Saltmarsh.Hollow.2031.mkv", 0),
      file("Sample/sample.mkv", 1),
      file("x.nfo", 2)
    ]

    sel =
      WantedFiles.select(
        %{media_item: movie, season_number: nil, targeted_episode_ids: []},
        files
      )

    assert sel.only_files == [0]
    assert sel.file_episodes == %{}
  end

  test "junk is whatever FileSelection calls junk" do
    paths = [
      "Saltmarsh.Hollow.2031.mkv",
      "Saltmarsh.Hollow.2031.ts",
      "Saltmarsh.Hollow.2031.en.srt",
      "Saltmarsh.Hollow.2031.idx",
      "Trailers/trailer.mkv",
      "Saltmarsh.Hollow.2031-sample.mkv",
      "poster.jpg"
    ]

    files = paths |> Enum.with_index() |> Enum.map(fn {path, i} -> file(path, i) end)

    sel =
      WantedFiles.select(%{media_item: nil, season_number: nil, targeted_episode_ids: []}, files)

    expected =
      for %{index: i, path: path} <- files,
          FileSelection.importable?(path) or FileSelection.subtitle?(path),
          do: i

    assert sel.only_files == expected
  end

  test "nil media item behaves like a movie" do
    sel =
      WantedFiles.select(
        %{media_item: nil, season_number: nil, targeted_episode_ids: []},
        [file("a.mkv", 0), file("a.nfo", 1)]
      )

    assert sel.only_files == [0]
  end

  test "to_metadata/1", %{show: show, ids: ids} do
    sel = WantedFiles.select(ctx(show, Enum.drop(ids, 4)), pack_files())
    meta = WantedFiles.to_metadata(sel)
    assert meta["selected_files"] == [4, 5, 6, 7, 8, 9]
    assert meta["file_episodes"]["4"] == Enum.at(ids, 4)
    assert length(meta["skipped_owned_episode_ids"]) == 4
    assert WantedFiles.to_metadata(nil) == %{}
  end

  describe "context_for/2" do
    test "reads season and episode ids from metadata", %{show: show, ids: ids} do
      result = %{metadata: %SearchResultMetadata{season_number: 2, episode_ids: ids}}
      ctx = WantedFiles.context_for(result, media_item_id: show.id)
      assert ctx.media_item.id == show.id
      assert ctx.season_number == 2
      assert ctx.targeted_episode_ids == ids
    end

    test "accepts plain-map and nil metadata", %{show: show} do
      ctx = WantedFiles.context_for(%{metadata: %{season_number: 2}}, media_item_id: show.id)
      assert ctx.season_number == 2 and ctx.targeted_episode_ids == []
      ctx = WantedFiles.context_for(%{metadata: nil}, media_item_id: show.id)
      assert ctx.season_number == nil
    end

    test "single episode grab includes episode id", %{show: show, eps: [ep | _]} do
      ctx = WantedFiles.context_for(%{metadata: nil}, media_item_id: show.id, episode_id: ep.id)
      assert ctx.targeted_episode_ids == [ep.id]
      assert ctx.single_episode?
      assert ctx.season_number == 2
    end

    test "no media item" do
      ctx = WantedFiles.context_for(%{metadata: nil}, [])
      assert ctx.media_item == nil
    end
  end
end
