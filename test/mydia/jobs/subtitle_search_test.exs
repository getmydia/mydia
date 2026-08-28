defmodule Mydia.Jobs.SubtitleSearchTest do
  use Mydia.DataCase, async: true

  alias Mydia.Jobs.SubtitleSearch
  alias Mydia.Library
  alias Mydia.MediaFixtures
  alias Mydia.SubtitleProviderFixtures
  alias Mydia.Subtitles.Health
  alias Mydia.Subtitles.ProviderRegistry

  # The default "Mydia Relay" provider is a real HTTP client. Even a request
  # this test expects to be rejected client-side (no imdb/tmdb/tvdb id) still
  # reaches the relay for server-side validation, which is a live network
  # call this suite must never make. Standing this adapter in for :relay
  # keeps the season-mode tests below fully offline.
  defmodule NoMatchAdapter do
    @moduledoc false
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_config, _params), do: {:ok, []}

    @impl true
    def download(_config, _info), do: {:error, :not_implemented}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_config), do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:relay)}

    @impl true
    def capabilities do
      %{
        media_types: [:movie, :episode],
        search_keys: [:tmdb_id, :imdb_id, :tvdb_id, :query],
        requires_credentials: false,
        quota: :unlimited
      }
    end
  end

  defp track(language) do
    %{
      track_id: 1,
      language: language,
      title: language,
      format: "srt",
      embedded: false,
      origin: :provider,
      deliverable: true,
      offset_ms: 0,
      resync_state: nil
    }
  end

  describe "missing_languages/2" do
    test "returns every wanted language for a file with no tracks" do
      assert SubtitleSearch.missing_languages([], ["en", "es"]) == ["en", "es"]
    end

    test "returns only the languages the file lacks" do
      assert SubtitleSearch.missing_languages([track("en")], ["en", "es"]) == ["es"]
    end

    test "returns nothing when the file has every wanted language" do
      assert SubtitleSearch.missing_languages([track("en"), track("es")], ["en", "es"]) == []
    end

    test "counts an embedded track as present" do
      embedded = %{track("en") | embedded: true, origin: :embedded}

      assert SubtitleSearch.missing_languages([embedded], ["en"]) == []
    end

    test "counts a sidecar track as present" do
      sidecar = %{track("en") | origin: :sidecar}

      assert SubtitleSearch.missing_languages([sidecar], ["en"]) == []
    end

    test "ignores a track in a language nobody asked for" do
      assert SubtitleSearch.missing_languages([track("de")], ["en"]) == ["en"]
    end
  end

  describe "perform/1 (season mode)" do
    setup do
      for %{type: type} <- ProviderRegistry.builtins(), do: Health.reset(type)
      SubtitleProviderFixtures.stub_registry_adapter(:relay, NoMatchAdapter)
      :ok
    end

    defp subtitle_stream(language) do
      %{
        "streams" => [
          %{"type" => "subtitle", "language" => language, "index" => 0, "codec" => "subrip"}
        ]
      }
    end

    test "processes only the season's non-trashed files, broadcasting per file and once at the end" do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show"})

      ep1 =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 1
        })

      ep2 =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 2
        })

      other_season_ep =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 2,
          episode_number: 1
        })

      missing_file =
        MediaFixtures.media_file_fixture(%{episode_id: ep1.id, metadata: %{"streams" => []}})

      trashed_file =
        MediaFixtures.media_file_fixture(%{episode_id: ep1.id, metadata: %{"streams" => []}})

      {:ok, _trashed_file} = Library.trash_media_file(trashed_file)

      _satisfied_file =
        MediaFixtures.media_file_fixture(%{episode_id: ep2.id, metadata: subtitle_stream("en")})

      _other_season_file =
        MediaFixtures.media_file_fixture(%{
          episode_id: other_season_ep.id,
          metadata: %{"streams" => []}
        })

      Phoenix.PubSub.subscribe(Mydia.PubSub, "subtitles")

      assert :ok =
               SubtitleSearch.perform(%Oban.Job{
                 args: %{"mode" => "season", "media_item_id" => show.id, "season_number" => 1}
               })

      assert_received {:subtitles_updated, updated_id}
      assert updated_id == missing_file.id

      refute_received {:subtitles_updated, _other}

      assert_received {:subtitle_season_finished, media_item_id, 1}
      assert media_item_id == show.id
    end

    test "still broadcasts the season-finished event when nothing is missing" do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show"})

      ep =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 1
        })

      MediaFixtures.media_file_fixture(%{episode_id: ep.id, metadata: subtitle_stream("en")})

      Phoenix.PubSub.subscribe(Mydia.PubSub, "subtitles")

      assert :ok =
               SubtitleSearch.perform(%Oban.Job{
                 args: %{"mode" => "season", "media_item_id" => show.id, "season_number" => 1}
               })

      refute_received {:subtitles_updated, _any}
      assert_received {:subtitle_season_finished, media_item_id, 1}
      assert media_item_id == show.id
    end
  end
end
