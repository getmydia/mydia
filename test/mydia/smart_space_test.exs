defmodule Mydia.SmartSpaceTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Config.Schema.SmartSpace, as: Config
  alias Mydia.Events.Event
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Playback.Progress
  alias Mydia.Repo
  alias Mydia.SmartSpace

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)
    :ok
  end

  defp cfg(attrs \\ %{}), do: struct(%Config{enabled: true}, attrs)

  defp ctx(tmp) do
    root = Path.join(tmp, "lib")
    File.mkdir_p!(root)

    %{
      root: root,
      lp: library_path_fixture(%{path: root, type: "series"}),
      show: media_item_fixture(%{type: "tv_show", title: "Harrowgate Nights"}),
      user: user_fixture()
    }
  end

  defp episode(c, season, number, attrs \\ %{}) do
    episode_fixture(
      Map.merge(
        %{
          media_item_id: c.show.id,
          season_number: season,
          episode_number: number,
          air_date: ~D[2020-01-01],
          monitored: true
        },
        attrs
      )
    )
  end

  defp file(c, ep, rel, content \\ "aaaa") do
    path = Path.join(c.root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    {:ok, f} =
      Library.create_scanned_media_file(%{
        relative_path: rel,
        library_path_id: c.lp.id,
        episode_id: ep.id,
        size: byte_size(content)
      })

    f
  end

  defp watch(c, ep, at) do
    Repo.insert!(%Progress{
      user_id: c.user.id,
      episode_id: ep.id,
      watched: true,
      position_seconds: 0,
      duration_seconds: 100,
      completion_percentage: 0.0,
      last_watched_at: at
    })
  end

  defp days_ago(n), do: DateTime.utc_now() |> DateTime.add(-n, :day) |> DateTime.truncate(:second)

  defp watched_season(c, season, files) do
    for n <- 1..files do
      ep = episode(c, season, n)
      f = file(c, ep, "s#{season}e#{n}.mkv")
      watch(c, ep, days_ago(30))
      {ep, f}
    end
  end

  defp events(type), do: Repo.all(from e in Event, where: e.type == ^type)

  describe "run/1" do
    @tag :tmp_dir
    test "trashes eligible files, unmonitors episodes, records events", %{tmp_dir: tmp} do
      c = ctx(tmp)
      [{e1, f1}, {e2, f2}] = watched_season(c, 1, 2)

      assert {:ok, %{cleanups: 1, files: 2, failed: 0, bytes: 8, capped?: false}} =
               SmartSpace.run(config: cfg())

      for f <- [f1, f2] do
        reloaded = Repo.get!(MediaFile, f.id)
        assert reloaded.trashed_reason == :smart_space
        assert reloaded.trashed_at
      end

      for e <- [e1, e2], do: refute(Repo.get!(Episode, e.id).monitored)

      assert [event] = events("smart_space.cleanup")
      assert event.resource_id == c.show.id
      assert event.severity == :info
      assert event.metadata["file_count"] == 2
      assert event.metadata["season_number"] == 1
      assert [_] = events("smart_space.run")
      assert %DateTime{} = SmartSpace.last_run_at()
    end

    @tag :tmp_dir
    test "a second run is a no-op", %{tmp_dir: tmp} do
      c = ctx(tmp)
      watched_season(c, 1, 2)
      assert {:ok, %{files: 2}} = SmartSpace.run(config: cfg())
      assert {:ok, %{cleanups: 0, files: 0, failed: 0}} = SmartSpace.run(config: cfg())
      assert [_] = events("smart_space.cleanup")
    end

    @tag :tmp_dir
    test "one failing file keeps its episode monitored", %{tmp_dir: tmp} do
      c = ctx(tmp)
      e1 = episode(c, 1, 1)
      bad = file(c, e1, "locked/s1e1.mkv")
      good = file(c, e1, "s1e1-alt.mkv", "bb")
      watch(c, e1, days_ago(30))
      File.chmod!(Path.join(c.root, "locked"), 0o500)
      on_exit(fn -> File.chmod(Path.join(c.root, "locked"), 0o700) end)

      assert {:ok, %{files: 1, failed: 1}} = SmartSpace.run(config: cfg())

      assert Repo.get!(MediaFile, good.id).trashed_at
      assert is_nil(Repo.get!(MediaFile, bad.id).trashed_at)
      assert Repo.get!(Episode, e1.id).monitored
    end

    @tag :tmp_dir
    test "cap never splits a season", %{tmp_dir: tmp} do
      c = ctx(tmp)
      [{_, a1}, {_, a2}] = watched_season(c, 1, 2)

      b =
        for n <- 1..2 do
          ep = episode(c, 2, n)
          f = file(c, ep, "s2e#{n}.mkv")
          watch(c, ep, days_ago(10))
          f
        end

      assert {:ok, %{cleanups: 1, files: 2, capped?: true}} =
               SmartSpace.run(config: cfg(), cap: 3)

      for f <- [a1, a2], do: assert(Repo.get!(MediaFile, f.id).trashed_at)
      for f <- b, do: assert(is_nil(Repo.get!(MediaFile, f.id).trashed_at))
    end

    @tag :tmp_dir
    test "nothing enabled: no work and no events", %{tmp_dir: tmp} do
      c = ctx(tmp)
      [{_, f}] = watched_season(c, 1, 1)

      assert {:ok, %{cleanups: 0, files: 0}} = SmartSpace.run(config: cfg(%{enabled: false}))
      assert is_nil(Repo.get!(MediaFile, f.id).trashed_at)
      assert Repo.all(from e in Event, where: like(e.type, "smart_space.%")) == []
      assert is_nil(SmartSpace.last_run_at())
    end

    @tag :tmp_dir
    test "disabled with stale selected users is not an error", %{tmp_dir: tmp} do
      c = ctx(tmp)
      watched_season(c, 1, 1)

      assert {:ok, %{cleanups: 0}} =
               SmartSpace.run(
                 config: cfg(%{enabled: false, watched_by: "selected", selected_users: ["ghost"]})
               )

      assert Repo.all(from e in Event, where: like(e.type, "smart_space.%")) == []
    end

    @tag :tmp_dir
    test "trashes only the approved files, not extras or late imports", %{tmp_dir: tmp} do
      c = ctx(tmp)
      ep = episode(c, 1, 1)
      version = file(c, ep, "s1e1.mkv")
      watch(c, ep, days_ago(30))

      {:ok, extra} =
        Library.create_scanned_media_file(%{
          relative_path: "s1e1-sample.mkv",
          library_path_id: c.lp.id,
          episode_id: ep.id,
          size: 3,
          extra_kind: "sample"
        })

      inputs = Mydia.SmartSpace.Loader.load(config: cfg())

      assert [%{file_ids: [id]}] =
               Mydia.SmartSpace.Evaluator.eligible(inputs, DateTime.utc_now(), Date.utc_today())

      assert id == version.id

      assert {:ok, %{files: 1}} = SmartSpace.run(config: cfg())
      assert Repo.get!(MediaFile, version.id).trashed_at
      assert is_nil(Repo.get!(MediaFile, extra.id).trashed_at)
    end

    @tag :tmp_dir
    test "a file imported after load survives", %{tmp_dir: tmp} do
      c = ctx(tmp)
      ep = episode(c, 1, 1)
      approved = file(c, ep, "s1e1.mkv")
      watch(c, ep, days_ago(30))
      late = file(c, ep, "s1e1-late.mkv", "zz")

      # Stand in for an import landing between load and trash.
      assert {:ok, %{trashed: [t]}} =
               Library.trash_media_files([approved.id], reason: :smart_space)

      assert t.id == approved.id
      assert is_nil(Repo.get!(MediaFile, late.id).trashed_at)
    end

    @tag :tmp_dir
    test "misconfigured selected users trash nothing and warn", %{tmp_dir: tmp} do
      c = ctx(tmp)
      [{_, f}] = watched_season(c, 1, 1)

      assert {:error, :misconfigured} =
               SmartSpace.run(config: cfg(%{watched_by: "selected", selected_users: ["ghost"]}))

      assert is_nil(Repo.get!(MediaFile, f.id).trashed_at)
      assert [%{severity: :warning}] = events("smart_space.misconfigured")
      assert events("smart_space.cleanup") == []
    end
  end

  describe "upcoming/1" do
    @tag :tmp_dir
    test "lists a season due soon, which run/1 leaves alone", %{tmp_dir: tmp} do
      c = ctx(tmp)
      ep = episode(c, 1, 1)
      f = file(c, ep, "s1e1.mkv")
      # Watched 2 days ago with a 7 day grace: due in 5 days.
      watch(c, ep, days_ago(2))

      assert [%{season_number: 1, eligible_at: at}] =
               SmartSpace.upcoming(within_days: 30, config: cfg())

      assert DateTime.compare(at, DateTime.utc_now()) == :gt

      assert [] = SmartSpace.upcoming(within_days: 1, config: cfg())
      assert {:ok, %{files: 0}} = SmartSpace.run(config: cfg())
      assert is_nil(Repo.get!(MediaFile, f.id).trashed_at)
    end
  end
end
