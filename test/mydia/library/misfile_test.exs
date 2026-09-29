defmodule Mydia.Library.MisfileTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.ImportCandidate
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

  describe "classify/3,4" do
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

    test "strict_titles flags a stray whose title the parser still binds" do
      {show, lp} = harbor_show()
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})
      good = episode_file(lp, e1, "Harbor Lights/Season 01/Harbor.Lights.S01E01.1080p.mkv")
      stray = episode_file(lp, e2, "Vardo/Season 01/Vardo.S01E02.1080p.mkv")
      target = target(show)

      # Precondition: the parser's own flag misses it (similarity 0.61 >= 0.5).
      refute Misfile.unbound?(stray, target)

      assert Misfile.classify([good, stray], target, & &1.episode).suspects == []

      assert %{suspects: [{%{id: id}, :unbound}]} =
               Misfile.classify([good, stray], target, & &1.episode, strict_titles: true)

      assert id == stray.id
    end
  end

  describe "scan/0" do
    test "finds a lone stray that collides with nothing" do
      {show, lp} = harbor_show()
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})
      episode_file(lp, e1, "Harbor Lights/Season 01/Harbor.Lights.S01E01.1080p.mkv")
      stray = episode_file(lp, e2, "Vardo/Season 01/Vardo.S01E02.1080p.mkv")

      assert [%Misfile.Finding{} = finding] = Misfile.scan()
      assert finding.media_item.id == show.id
      assert finding.file_count == 2
      assert [{%{id: id}, :unbound}] = finding.suspects
      assert id == stray.id
      refute finding.nothing_binds?
    end

    test "ignores classified extras and items with nothing wrong" do
      movie = media_item_fixture(%{type: "movie", title: "Zephyr Station", year: 2030})
      lp = library_path_fixture(%{type: "movies"})

      media_file_fixture(%{
        media_item_id: movie.id,
        library_path_id: lp.id,
        relative_path: "Zephyr Station (2030)/Zephyr.Station.2030.1080p.mkv"
      })

      # `MediaFile.changeset/2` does not cast `extra_kind`, so set it directly.
      %{
        media_item_id: movie.id,
        library_path_id: lp.id,
        relative_path: "Starveil (2031)/Featurettes/Outtakes.mkv"
      }
      |> media_file_fixture()
      |> Ecto.Changeset.change(extra_kind: :featurette)
      |> Repo.update!()

      assert Misfile.scan() == []
    end

    test "skips trashed files" do
      {show, lp} = harbor_show()
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      episode_file(lp, e1, "Harbor Lights/Season 01/Harbor.Lights.S01E01.1080p.mkv")
      stray = episode_file(lp, e1, "Vardo/Season 01/Vardo.S01E01.1080p.mkv")

      stray
      |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      assert Misfile.scan() == []
    end
  end

  describe "send_to_review/2" do
    setup do
      {show, lp} = harbor_show()
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})
      good = episode_file(lp, e1, "Harbor Lights/Season 01/Harbor.Lights.S01E01.1080p.mkv")
      stray = episode_file(lp, e2, "Vardo/Season 01/Vardo.S01E02.1080p.mkv")
      user = Mydia.AccountsFixtures.user_fixture()
      %{good: good, stray: stray, actor: to_string(user.id)}
    end

    test "returns a current suspect to review", %{stray: stray, actor: actor} do
      assert %{returned: [%{id: id}], failed: [], aborted: []} =
               Misfile.send_to_review([stray.id], actor)

      assert id == stray.id

      assert %ImportCandidate{returned_at: %DateTime{}} =
               Repo.get_by(ImportCandidate, relative_path: stray.relative_path)
    end

    test "refuses a file that is not a suspect", %{good: good, actor: actor} do
      assert %{returned: [], aborted: [{id, :not_a_suspect}]} =
               Misfile.send_to_review([good.id], actor)

      assert id == good.id
    end

    test "refuses to empty an item" do
      movie = media_item_fixture(%{type: "movie", title: "Zephyr Station", year: 2030})
      lp = library_path_fixture(%{type: "movies"})

      only =
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: lp.id,
          relative_path: "Starveil (2031)/Starveil.2031.1080p.mkv"
        })

      actor = to_string(Mydia.AccountsFixtures.user_fixture().id)

      assert %{returned: [], aborted: [{id, :would_leave_no_file}]} =
               Misfile.send_to_review([only.id], actor)

      assert id == only.id
    end
  end
end
