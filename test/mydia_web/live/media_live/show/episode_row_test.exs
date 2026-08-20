defmodule MydiaWeb.MediaLive.Show.EpisodeRowTest do
  @moduledoc """
  The episode row's controls are icon-only, so their DOM ids are the only stable
  handle a test has.

  `episode_rows/1` is private, so these drive the public `season_section/1` with
  `expanded?: true` instead — the same `render_component/2` approach
  `season_collapse_test.exs` already uses for `season_header/1`. That path
  touches neither the database nor a connection, so this file is `async: true`;
  the `async: false` Postgres-sandbox rule is only for connected LiveView tests.
  """
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Media.AvailabilityStatus
  alias MydiaWeb.MediaLive.Show.Helpers

  describe "episode_status_label/1" do
    test "names the state" do
      status = %AvailabilityStatus{state: :missing, monitored: true}

      assert Helpers.episode_status_label(status) == "Missing"
    end

    test "marks an unmonitored item so the faded chip explains itself" do
      status = %AvailabilityStatus{state: :downloaded, monitored: false}

      assert Helpers.episode_status_label(status) == "Downloaded · Not monitored"
    end
  end
end
