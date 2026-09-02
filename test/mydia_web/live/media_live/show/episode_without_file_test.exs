defmodule MydiaWeb.MediaLive.Show.EpisodeWithoutFileTest do
  @moduledoc """
  An episode with no file must still open and say why.

  The season list used to gate its disclosure on `has_files`, rendering
  `phx-click={false}` for a file-less episode. The row that most needed
  explaining was the only one that could not be opened, which is what a
  multi-episode release turns into: the trailing episode looks un-downloaded
  and the page has nothing to say about it.
  """
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Downloads.Download
  alias Mydia.Media.Episode
  alias MydiaWeb.MediaLive.Show.SeasonComponents

  @episode_id "11111111-1111-4111-8111-111111111111"

  defp episode(attrs) do
    struct!(
      %Episode{
        id: @episode_id,
        season_number: 1,
        episode_number: 10,
        title: "Tidewater",
        monitored: true,
        air_date: ~D[2024-01-01],
        media_files: [],
        downloads: []
      },
      attrs
    )
  end

  defp render_season(episodes) do
    render_component(&SeasonComponents.season_section/1,
      season_number: 1,
      episodes: episodes,
      expanded?: true,
      expanded_episodes: MapSet.new(Enum.map(episodes, & &1.id)),
      playback_enabled: false,
      segment_detection_available: false
    )
  end

  describe "the row is openable" do
    test "a file-less episode still carries the expand handler" do
      html = render_season([episode(%{})])

      assert html =~ "toggle_episode_expanded"
      assert html =~ "episode-#{@episode_id}-no-file"
    end
  end

  describe "what the open row says" do
    test "names the state when nothing has been downloaded" do
      html = render_season([episode(%{})])

      assert html =~ "Missing"
      assert html =~ "No download has been recorded"
    end

    test "surfaces an import failure instead of silence" do
      download = %Download{
        id: "22222222-2222-4222-8222-222222222222",
        title: "Fathom Rift S01E10 1080p",
        import_failure_reason: "no matching episode"
      }

      html = render_season([episode(%{downloads: [download]})])

      assert html =~ "Downloads for this episode"
      assert html =~ "Fathom Rift S01E10 1080p"
      assert html =~ "Import failed: no matching episode"
      refute html =~ "No download has been recorded"
    end

    test "says an episode is not monitored when it is not" do
      html = render_season([episode(%{monitored: false})])

      assert html =~ "Not monitored"
    end
  end
end
