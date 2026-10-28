defmodule Mydia.Media.MonitoringPreviewTest do
  use Mydia.DataCase

  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode

  defp ep(season, opts) do
    %Episode{
      id: Ecto.UUID.generate(),
      season_number: season,
      air_date: Keyword.get(opts, :air_date, ~D[2020-01-01]),
      media_files: if(Keyword.get(opts, :file?, false), do: [%MediaFile{}], else: []),
      monitored: false
    }
  end

  defp future, do: Date.add(Date.utc_today(), 30)

  describe "monitoring_preview/1" do
    test "an empty show previews zero for every preset" do
      assert Media.monitoring_preview([]) ==
               %{all: 0, missing: 0, existing: 0, future: 0, none: 0}
    end

    test "a show with no future episodes previews zero for :future" do
      episodes = [ep(1, file?: true), ep(1, []), ep(2, [])]

      preview = Media.monitoring_preview(episodes)

      assert preview.future == 0
      assert preview.all == 3
      assert preview.missing == 2
      assert preview.existing == 1
      assert preview.none == 0
    end

    test "all aired and all with files previews zero for :missing and :future" do
      episodes = [ep(1, file?: true), ep(1, file?: true)]

      assert Media.monitoring_preview(episodes) ==
               %{all: 2, missing: 0, existing: 2, future: 0, none: 0}
    end

    test "a mixed show counts each preset, never sweeping in specials" do
      episodes = [
        ep(0, []),
        ep(1, file?: true),
        ep(1, []),
        ep(2, air_date: future()),
        ep(2, air_date: nil)
      ]

      assert Media.monitoring_preview(episodes) ==
               %{all: 4, missing: 3, existing: 1, future: 1, none: 0}
    end

    test "each preset's preview count matches what applying it monitors" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      with_file =
        episode_fixture(
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: 1,
          air_date: ~D[2020-01-01]
        )

      media_file_fixture(episode_id: with_file.id)

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 2,
        air_date: ~D[2020-01-08]
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 2,
        episode_number: 1,
        air_date: future()
      )

      episode_fixture(media_item_id: media_item.id, season_number: 0, episode_number: 1)

      load = fn ->
        Media.list_episodes(Scope.unrestricted(), media_item.id, preload: [:media_files])
      end

      preview = Media.monitoring_preview(load.())

      for preset <- Media.monitoring_presets() do
        {:ok, _} = Media.apply_episode_monitoring(media_item, preset)
        monitored = Enum.count(load.(), & &1.monitored)

        assert preview[preset] == monitored,
               "#{preset}: preview #{preview[preset]}, applied #{monitored}"
      end
    end
  end
end
