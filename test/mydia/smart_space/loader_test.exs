defmodule Mydia.SmartSpace.LoaderTest do
  use Mydia.DataCase

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures

  alias Mydia.Config.Schema.SmartSpace, as: Config
  alias Mydia.Library.MediaFile
  alias Mydia.Playback.Progress
  alias Mydia.Repo
  alias Mydia.SmartSpace.Inputs.KeepRef
  alias Mydia.SmartSpace.{Loader, Rules}

  defp cfg(attrs \\ %{}), do: struct(%Config{enabled: true}, attrs)
  defp show(title), do: media_item_fixture(%{type: "tv_show", title: title})

  defp ep(show, season, number, attrs \\ %{}),
    do:
      episode_fixture(
        Map.merge(%{media_item_id: show.id, season_number: season, episode_number: number}, attrs)
      )

  defp watch!(user, episode, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Progress{
          user_id: user.id,
          episode_id: episode.id,
          watched: true,
          position_seconds: 0,
          duration_seconds: 100,
          completion_percentage: 0.0,
          last_watched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
  end

  defp find(inputs, show), do: Enum.find(inputs.shows, &(&1.media_item_id == show.id))

  test "builds structs for two shows, with every episode and only own watches" do
    a = show("Harbor Lights")
    b = show("Quiet Orchard")
    a1 = ep(a, 1, 1, %{air_date: ~D[2020-01-01]})
    a2 = ep(a, 1, 2, %{monitored: false})
    b1 = ep(b, 1, 1)
    f = media_file_fixture(%{episode_id: a1.id, size: 42})
    u = user_fixture()
    watch!(u, a1)
    watch!(u, b1)

    inputs = Loader.load(config: cfg())

    assert inputs.global == %{
             enabled: true,
             unit: "season",
             grace_days: 7,
             watched_by: "all_started"
           }

    assert inputs.selected_user_ids == []

    sa = find(inputs, a)
    sb = find(inputs, b)
    assert sa.title == "Harbor Lights"
    assert sa.override == nil
    assert Enum.sort(Enum.map(sa.episodes, & &1.id)) == Enum.sort([a1.id, a2.id])
    e1 = Enum.find(sa.episodes, &(&1.id == a1.id))
    assert e1.files == [{f.id, 42}]
    assert e1.air_date == ~D[2020-01-01]
    assert [%{episode_id: id}] = sa.watches
    assert id == a1.id
    assert [%{episode_id: id}] = sb.watches
    assert id == b1.id
  end

  test "trashed files excluded, two versions both included, extras excluded" do
    s = show("Harbor Lights")
    e = ep(s, 1, 1)
    f1 = media_file_fixture(%{episode_id: e.id, size: 10})
    f2 = media_file_fixture(%{episode_id: e.id, size: 20})
    t = media_file_fixture(%{episode_id: e.id, size: 30})

    t
    |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    x = media_file_fixture(%{episode_id: e.id, size: 40})
    x |> Ecto.Changeset.change(extra_kind: :sample) |> Repo.update!()
    assert %MediaFile{} = x

    [show] = Loader.load(config: cfg()).shows
    [ep] = show.episodes
    assert Enum.sort(ep.files) == Enum.sort([{f1.id, 10}, {f2.id, 20}])
  end

  test "watches on episodes with trashed files are kept; nil episode ignored" do
    s = show("Harbor Lights")
    e = ep(s, 1, 1)
    f = media_file_fixture(%{episode_id: e.id})

    f
    |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    u = user_fixture()
    watch!(u, e)

    Repo.insert!(%Progress{
      user_id: u.id,
      position_seconds: 0,
      duration_seconds: 100,
      completion_percentage: 0.0,
      media_item_id: media_item_fixture(%{type: "movie"}).id
    })

    [show] = Loader.load(config: cfg()).shows
    assert [%{user_id: uid}] = show.watches
    assert uid == u.id
  end

  test "deleted selected username gives :misconfigured; resolved only for selected" do
    u = user_fixture()
    c = cfg(%{watched_by: "selected", selected_users: [u.username]})
    assert Loader.load(config: c).selected_user_ids == [u.id]

    c = cfg(%{watched_by: "selected", selected_users: [u.username, "ghost"]})
    assert Loader.load(config: c).selected_user_ids == :misconfigured

    c = cfg(%{watched_by: "any", selected_users: ["ghost"]})
    assert Loader.load(config: c).selected_user_ids == []
  end

  test "in flight: episode download marks the episode, season pack marks the show" do
    a = show("Harbor Lights")
    b = show("Quiet Orchard")
    a1 = ep(a, 1, 1)
    a2 = ep(a, 1, 2)
    ep(b, 1, 1)
    download_fixture(%{media_item_id: a.id, episode_id: a1.id})
    download_fixture(%{media_item_id: b.id})

    inputs = Loader.load(config: cfg())
    sa = find(inputs, a)
    assert sa.in_flight_show? == false
    assert Enum.find(sa.episodes, &(&1.id == a1.id)).in_flight?
    refute Enum.find(sa.episodes, &(&1.id == a2.id)).in_flight?
    assert find(inputs, b).in_flight_show?
  end

  test "keeps map to levels with the right fields" do
    s = show("Harbor Lights")
    e = ep(s, 2, 1)
    {:ok, _} = Rules.keep({:show, s.id}, nil)
    {:ok, _} = Rules.keep({:season, s.id, 2}, nil)
    {:ok, _} = Rules.keep({:episode, s.id, e.id}, nil)

    [show] = Loader.load(config: cfg()).shows
    assert %KeepRef{level: :show, season_number: nil, episode_id: nil} in show.keeps
    assert %KeepRef{level: :season, season_number: 2, episode_id: nil} in show.keeps
    assert %KeepRef{level: :episode, season_number: nil, episode_id: e.id} in show.keeps
  end

  test "selection: enabled minus off; disabled only custom; movies never; narrowing" do
    a = show("Harbor Lights")
    b = show("Quiet Orchard")
    c = show("Salt Meadow")
    media_item_fixture(%{type: "movie"})
    {:ok, _} = Rules.put_override(b.id, %{mode: "off"})
    {:ok, _} = Rules.put_override(c.id, %{mode: "custom", unit: "episode", grace_days: 2})

    ids = fn i -> i.shows |> Enum.map(& &1.media_item_id) |> Enum.sort() end
    assert ids.(Loader.load(config: cfg())) == Enum.sort([a.id, c.id])
    assert ids.(Loader.load(config: cfg(%{enabled: false}))) == [c.id]

    sc = find(Loader.load(config: cfg()), c)
    assert sc.override == %{mode: "custom", unit: "episode", grace_days: 2}

    narrowed = Loader.load(config: cfg(%{enabled: false}), media_item_id: b.id)
    assert ids.(narrowed) == [b.id]
    assert hd(narrowed.shows).override.mode == "off"
  end
end
