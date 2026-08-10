defmodule MydiaWeb.MediaLive.Show.EpisodeStatusRenderingTest do
  @moduledoc """
  The show page renders each episode badge as
  `<span class={["badge badge-xs", episode_status_color(status)]}>`, so these assert on
  the classes and icon that markup receives.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias MydiaWeb.MediaLive.Show.Helpers

  defp episode(attrs) do
    struct!(
      %Episode{monitored: true, air_date: ~D[2024-01-01], media_files: [], downloads: []},
      attrs
    )
  end

  test "an unmonitored aired episode with no file renders a muted missing badge" do
    status = Helpers.get_episode_status(episode(monitored: false))

    assert Helpers.episode_status_icon(status) == "hero-exclamation-circle"
    assert Helpers.episode_status_color(status) == "badge-error badge-outline opacity-60"
  end

  test "a monitored aired episode with no file renders a solid missing badge" do
    status = Helpers.get_episode_status(episode(monitored: true))

    assert Helpers.episode_status_icon(status) == "hero-exclamation-circle"
    assert Helpers.episode_status_color(status) == "badge-error"
  end

  test "an unmonitored episode with a file renders a muted downloaded badge" do
    status = Helpers.get_episode_status(episode(monitored: false, media_files: [%MediaFile{}]))

    assert Helpers.episode_status_icon(status) == "hero-check-circle"
    assert Helpers.episode_status_color(status) == "badge-success badge-outline opacity-60"
  end

  test "no episode renders the retired eye-slash icon" do
    for monitored <- [true, false] do
      status = Helpers.get_episode_status(episode(monitored: monitored))

      refute Helpers.episode_status_icon(status) == "hero-eye-slash"
    end
  end
end
