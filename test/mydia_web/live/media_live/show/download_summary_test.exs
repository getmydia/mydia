defmodule MydiaWeb.MediaLive.Show.DownloadSummaryTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias MydiaWeb.MediaLive.Show.DownloadSummary

  defp download(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        title: "Lantern.Hollow.S02E04.1080p",
        status: "downloading",
        progress: 50.0,
        size: 1_000,
        eta: nil,
        episode_id: nil,
        episode: nil,
        metadata: %{}
      },
      attrs
    )
  end

  defp episode(id, season, number, files \\ []) do
    %Episode{id: id, season_number: season, episode_number: number, media_files: files}
  end

  test "returns nil when nothing is actively downloading" do
    assert DownloadSummary.build([download(%{status: "seeding"})], []) == nil
    assert DownloadSummary.build([download(%{status: "completed"})], []) == nil
    assert DownloadSummary.build([], []) == nil
  end

  test "leaves seeding downloads out of the items" do
    episodes = [episode("e1", 2, 4), episode("e2", 2, 5)]

    summary =
      DownloadSummary.build(
        [
          download(%{episode_id: "e1", status: "seeding"}),
          download(%{episode_id: "e2"})
        ],
        episodes
      )

    assert [%{episode_number: 5}] = summary.items
    assert Map.keys(summary.by_episode) == ["e2"]
  end

  test "orders items by season and episode, with a pack ahead of its season's episodes" do
    episodes = [episode("e1", 2, 7), episode("e2", 1, 3), episode("e3", 2, 1)]

    summary =
      DownloadSummary.build(
        [
          download(%{episode_id: "e1"}),
          download(%{metadata: %{"season_pack" => true, "season_number" => 2}}),
          download(%{episode_id: "e2"})
        ],
        episodes
      )

    assert Enum.map(summary.items, &{&1.kind, &1.season_number, &1.episode_number}) == [
             {:episode, 1, 3},
             {:season_pack, 2, nil},
             {:episode, 2, 7}
           ]
  end

  test "a season pack covers its season's episodes that have no file" do
    episodes = [
      episode("e1", 3, 1, [%MediaFile{id: "f1"}]),
      episode("e2", 3, 2),
      episode("e3", 4, 1)
    ]

    pack = download(%{metadata: %{"season_pack" => true, "season_number" => 3}})
    summary = DownloadSummary.build([pack], episodes)

    assert summary.by_episode == %{"e2" => pack}
    assert DownloadSummary.for_episode(summary, "e2") == pack
    assert DownloadSummary.for_episode(summary, "e3") == nil
    assert DownloadSummary.for_episode(nil, "e2") == nil
  end

  test "an episode's own download wins over a pack covering it" do
    episodes = [episode("e1", 1, 1)]
    own = download(%{episode_id: "e1"})
    pack = download(%{metadata: %{"season_pack" => true, "season_number" => 1}})

    assert DownloadSummary.build([own, pack], episodes).by_episode == %{"e1" => own}
  end

  test "weights progress by size when every download reports one" do
    summary =
      DownloadSummary.build(
        [download(%{progress: 100.0, size: 1_000}), download(%{progress: 10.0, size: 9_000})],
        []
      )

    assert summary.progress == 19.0
  end

  test "falls back to a plain mean when a size is missing" do
    summary =
      DownloadSummary.build(
        [download(%{progress: 100.0, size: nil}), download(%{progress: 20.0})],
        []
      )

    assert summary.progress == 60.0
  end

  test "names a state only when every download shares it" do
    assert DownloadSummary.build([download(%{status: "paused"})], []).state == "paused"

    assert DownloadSummary.build(
             [download(%{status: "paused"}), download(%{status: "downloading"})],
             []
           ).state == nil

    assert DownloadSummary.build([download(%{})], []).state == nil
  end

  test "the eta is the slowest download's" do
    summary = DownloadSummary.build([download(%{eta: 60}), download(%{eta: 600})], [])
    assert summary.eta == 600
  end

  test "tolerates episodes that are not loaded" do
    summary = DownloadSummary.build([download(%{})], %Ecto.Association.NotLoaded{})
    assert [%{kind: :other}] = summary.items
  end
end
