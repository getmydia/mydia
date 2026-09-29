defmodule Mydia.Library.MisfileTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.Misfile
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Repo

  defp harbor_show do
    show = media_item_fixture(%{type: "tv_show", title: "Harbor Lights", year: 2013})
    lp = library_path_fixture(%{type: "series"})
    {show, lp}
  end

  defp episode_file(lp, episode, path) do
    %{episode_id: episode.id, library_path_id: lp.id, relative_path: path}
    |> media_file_fixture()
    |> Repo.preload([:library_path, :episode])
  end

  defp target(show),
    do: show |> Repo.preload(:episodes, force: true) |> TargetContext.from_media_item()

  describe "classify/3" do
    test "flags another show's file sitting in that show's folder" do
      {show, lp} = harbor_show()
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})

      good = episode_file(lp, e1, "Harbor Lights/Season 01/Harbor.Lights.S01E01.1080p.mkv")
      stray = episode_file(lp, e2, "Quillmoor/Season 01/Quillmoor.S01E02.1080p.mkv")

      result = Misfile.classify([good, stray], target(show), & &1.episode)

      assert result.suspects |> Enum.map(fn {f, r} -> {f.id, r} end) == [{stray.id, :unbound}]
      refute result.nothing_binds?
    end

    test "flags a wrong-episode file in the show's own folder" do
      {show, lp} = harbor_show()
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      file = episode_file(lp, e1, "Harbor Lights/Season 01/Harbor.Lights.S01E05.1080p.mkv")

      assert %{suspects: [{%{id: id}, :wrong_episode}]} =
               Misfile.classify([file], target(show), & &1.episode)

      assert id == file.id
    end

    test "reports nothing_binds? when no file binds" do
      movie = media_item_fixture(%{type: "movie", title: "Zephyr Station", year: 2030})
      lp = library_path_fixture(%{type: "movies"})

      file =
        %{
          media_item_id: movie.id,
          library_path_id: lp.id,
          relative_path: "Starveil (2031)/Starveil.2031.1080p.mkv"
        }
        |> media_file_fixture()
        |> Repo.preload([:library_path, :episode])

      result = Misfile.classify([file], target(movie), fn _ -> nil end)

      assert [{%{id: id}, :unbound}] = result.suspects
      assert id == file.id
      assert result.nothing_binds?
    end
  end
end
