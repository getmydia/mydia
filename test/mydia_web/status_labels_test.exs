defmodule MydiaWeb.StatusLabelsTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.FailureCategory
  alias Mydia.Health.Rollup
  alias Mydia.Indexers.CardigannSummary
  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Media.ContentRating
  alias Mydia.Media.Episode
  alias Mydia.Media.EpisodeStatus
  alias Mydia.Media.MediaCategory
  alias Mydia.Plugins.PageWrites
  alias MydiaWeb.StatusLabels

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  @states [:downloaded, :downloading, :missing, :partial, :upcoming, :tba]

  describe "availability/1" do
    test "matches the domain label for every state, monitored or not" do
      for state <- @states, monitored <- [true, false] do
        status = %AvailabilityStatus{state: state, monitored: monitored}

        assert StatusLabels.availability(status) == AvailabilityStatus.label(status)
      end
    end
  end

  describe "episode_detail/1" do
    defp episode(attrs), do: struct!(%Episode{monitored: true, media_files: []}, attrs)

    test "matches the domain text for files, downloads and air dates" do
      today = Date.utc_today()
      active = %{imported_at: nil, error_message: nil, import_failed_at: nil}

      episodes = [
        episode(media_files: [%{resolution: "1080p"}]),
        episode(media_files: [%{resolution: "720p"}, %{resolution: "2160p"}]),
        episode(media_files: [%{resolution: nil}]),
        episode(media_files: [%{resolution: "1080p"}], monitored: false),
        episode(downloads: [], air_date: nil),
        episode(downloads: [], air_date: Date.add(today, -3)),
        episode(downloads: [], air_date: today),
        episode(downloads: [], air_date: Date.add(today, 1)),
        episode(downloads: [], air_date: Date.add(today, 4)),
        episode(downloads: [], air_date: Date.add(today, 40)),
        episode(downloads: [active, active], air_date: Date.add(today, -3)),
        episode(downloads: [Map.put(active, :progress, 41.6)], air_date: Date.add(today, -3)),
        episode(downloads: [%{active | imported_at: DateTime.utc_now()}], air_date: nil),
        episode(air_date: nil, monitored: false)
      ]

      for episode <- episodes do
        assert StatusLabels.episode_detail(episode) == EpisodeStatus.status_details(episode)
      end
    end
  end

  describe "rollup/1 and cardigann/1" do
    test "match the domain text" do
      rollups = [
        %Rollup{healthy: 0, unhealthy: 0, unknown: 0, total: 0, state: :none},
        %Rollup{healthy: 0, unhealthy: 0, unknown: 2, total: 2, state: :checking},
        %Rollup{healthy: 1, unhealthy: 0, unknown: 1, total: 3, state: :ok},
        %Rollup{healthy: 2, unhealthy: 1, unknown: 0, total: 3, state: :degraded}
      ]

      for rollup <- rollups, do: assert(StatusLabels.rollup(rollup) == Rollup.label(rollup))

      for engine <- [:builtin, :prowlarr] do
        summary = %CardigannSummary{engine: engine, enabled: 3, installed: 7}

        assert StatusLabels.cardigann_engine(engine) == CardigannSummary.engine_label(engine)
        assert StatusLabels.cardigann(summary) == CardigannSummary.label(summary)
      end
    end
  end

  describe "content_rating_thresholds/1" do
    test "matches the domain ladder" do
      assert StatusLabels.content_rating_thresholds() == ContentRating.thresholds()
    end
  end

  describe "page_write_surface/1" do
    test "matches the domain label for each surface, and falls back for unknown ones" do
      for surface <- [
            "playback:watched",
            "collections:favorite",
            "collections:write",
            "media:add"
          ] do
        assert StatusLabels.page_write_surface(surface) == PageWrites.surface_label(surface)
      end

      assert StatusLabels.page_write_surface("other:thing") == "other:thing"
    end
  end

  describe "regional_source/2" do
    test "matches the domain label for every source" do
      for source <- [:in_cinemas, :coming_soon, {:service, 8, "Fakeflix"}] do
        assert StatusLabels.regional_source(source, "US") ==
                 Mydia.Metadata.RegionalSources.label(source, "US")
      end
    end
  end

  describe "media_category/1" do
    test "matches the domain label for every category" do
      for category <- MediaCategory.all() do
        assert StatusLabels.media_category(category) == MediaCategory.label(category)
      end
    end
  end

  describe "failure_category/1" do
    test "matches the domain phrase for atoms, slugs and nil" do
      atoms = [:no_peers, :missing_files, :rejected_content, :provider_error]

      for category <- atoms do
        assert StatusLabels.failure_category(category) == FailureCategory.label(category)

        slug = FailureCategory.slug(category)
        assert StatusLabels.failure_category(slug) == FailureCategory.label(slug)
      end

      assert StatusLabels.failure_category(nil) == FailureCategory.label(nil)

      assert StatusLabels.failure_category("client_reported_failure") ==
               FailureCategory.label("client_reported_failure")
    end

    test "falls back to the humanized slug for an unknown one" do
      assert StatusLabels.failure_category("some_new_reason") == "some new reason"
    end
  end
end
