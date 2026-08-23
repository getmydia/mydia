defmodule Mydia.SubtitlesTest do
  # Not async: the provider-type fallback test stubs the relay by setting
  # :subtitle_relay_url, which is global application state.
  use Mydia.DataCase, async: false

  defmodule RecordingAdapter do
    @behaviour Mydia.Subtitles.Provider

    # A named config can opt into returning a single high-confidence result,
    # so a test can drive the full search_subtitles/2 auto-download path
    # without a real upstream. Every other config searches empty, same as
    # before.
    @impl true
    def search(%{name: "auto-download-match"}, _params) do
      {:ok,
       [
         %Mydia.Subtitles.Provider.SearchResult{
           file_id: "auto-1",
           language: "en",
           format: "srt",
           subtitle_hash: "auto-download-hash",
           rating: 10.0,
           download_count: 10_000,
           hearing_impaired: false,
           moviehash_match: false
         }
       ]}
    end

    def search(_config, _params), do: {:ok, []}

    # Records what it was handed so the test can assert the file id survived
    # the trip intact, and returns a valid SRT body.
    @impl true
    def download(config, info) do
      send(self(), {:downloaded, Map.get(config, :name), info.file_id})
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nhi\n"}
    end

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_config),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:relay)}

    @impl true
    def capabilities do
      %{
        media_types: [:movie],
        search_keys: [:tmdb_id],
        requires_credentials: false,
        quota: :unlimited
      }
    end
  end

  describe "auto-download confidence" do
    # SubDL cannot report a hash match, so a metadata match plus a decent
    # rating and download count has to be enough to clear the bar. If it is
    # not, the auto_download option is dead code.
    test "a metadata-only match can reach the auto-download threshold" do
      results =
        Mydia.Subtitles.score_results(
          [
            %{
              file_id: 1,
              language: "en",
              rating: 8.0,
              download_count: 5_000,
              moviehash_match: false
            }
          ],
          %{languages: "en", imdb_id: "0133093"},
          nil
        )

      assert [%{score: score}] = results
      assert score >= Mydia.Subtitles.high_confidence_threshold()
    end
  end

  describe "download_from_result/2" do
    alias Mydia.MediaFixtures
    alias Mydia.SubtitleProviderFixtures

    setup do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})
      media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      {:ok, media_file: media_file}
    end

    # Defect A: relay file ids are base64url strings, never integers. Any
    # numeric coercion anywhere on this path is a crash.
    test "carries a string file id through untouched", %{media_file: media_file} do
      config = SubtitleProviderFixtures.config_fixture(%{adapter: RecordingAdapter})

      result = %{
        file_id: "L3N1YnRpdGxlLzM0NjczMzAtODM5MDM4OS56aXA",
        language: "en",
        format: "srt",
        subtitle_hash: "relay-hash",
        provider_id: config.id,
        provider_type: config.type,
        provider_name: config.name
      }

      assert {:ok, _subtitle} = Mydia.Subtitles.download_from_result(result, media_file.id)
      assert_received {:downloaded, _name, "L3N1YnRpdGxlLzM0NjczMzAtODM5MDM4OS56aXA"}
    end

    # Defect B: the download must reach the provider that produced the result,
    # not whatever the downloader defaults to.
    test "downloads through the config the result came from", %{media_file: media_file} do
      other = SubtitleProviderFixtures.config_fixture(%{adapter: RecordingAdapter, name: "wrong"})

      chosen =
        SubtitleProviderFixtures.config_fixture(%{adapter: RecordingAdapter, name: "right"})

      result = %{
        file_id: "abc",
        language: "en",
        format: "srt",
        subtitle_hash: "routing-hash",
        provider_id: chosen.id,
        provider_type: chosen.type,
        provider_name: chosen.name
      }

      assert {:ok, _subtitle} = Mydia.Subtitles.download_from_result(result, media_file.id)
      assert_received {:downloaded, "right", _file_id}

      # A pin needs a bound variable; `^other.name` is not valid in a pattern.
      wrong_name = other.name
      refute_received {:downloaded, ^wrong_name, _}
    end

    # No config matches "deleted-config-id", so this rides the relay's own
    # zero-config default (Mydia.Subtitles.Provider.Relay) instead of a
    # provider_config resolved from a database row. A database-only stub
    # (stub_registry_adapter/2) can't reach that code path: the downloader's
    # own default_config/1 resolves straight from ProviderRegistry.default_configs/0
    # and never looks at the database. So the relay's real HTTP boundary is
    # stubbed here instead, the same way test/mydia/subtitles/provider/relay_test.exs
    # stubs it, with the same on_exit restore of the global config it touches.
    test "falls back to the provider type when the config is gone", %{media_file: media_file} do
      bypass = Bypass.open()
      original_relay_url = Application.get_env(:mydia, :subtitle_relay_url)
      Application.put_env(:mydia, :subtitle_relay_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.put_env(:mydia, :subtitle_relay_url, original_relay_url) end)

      Bypass.expect_once(bypass, "GET", "/api/v1/subtitles/download-url/def", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"download_url" => "http://localhost:#{bypass.port}/files/def.srt"})
        )
      end)

      Bypass.expect_once(bypass, "GET", "/files/def.srt", fn conn ->
        Plug.Conn.resp(conn, 200, "1\n00:00:01,000 --> 00:00:02,000\nhi\n")
      end)

      result = %{
        file_id: "def",
        language: "en",
        format: "srt",
        subtitle_hash: "fallback-hash",
        provider_id: "deleted-config-id",
        provider_type: :relay,
        provider_name: "Mydia Relay"
      }

      assert {:ok, _subtitle} = Mydia.Subtitles.download_from_result(result, media_file.id)
    end
  end

  describe "search_subtitles/2 auto_download" do
    alias Mydia.MediaFixtures
    alias Mydia.SubtitleProviderFixtures
    alias Mydia.Subtitles.Health

    setup do
      # Health is a singleton keyed by provider type; a circuit opened by a
      # concurrent test elsewhere in the suite would make the :relay-typed
      # configs below look unavailable and skip them.
      for %{type: type} <- Mydia.Subtitles.ProviderRegistry.builtins(), do: Health.reset(type)

      movie =
        MediaFixtures.media_item_fixture(%{
          type: "movie",
          tmdb_id: System.unique_integer([:positive])
        })

      media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      {:ok, media_file: media_file}
    end

    # Defect B, exercised through the auto-download branch instead of a
    # hand-built result: the download must reach the config the candidate's
    # provider_id names, not the relay default the old hand-rolled
    # download_opts fell back to.
    test "auto-download resolves the provider config from provider_id", %{media_file: media_file} do
      SubtitleProviderFixtures.config_fixture(%{adapter: RecordingAdapter, name: "wrong"})

      SubtitleProviderFixtures.config_fixture(%{
        adapter: RecordingAdapter,
        name: "auto-download-match"
      })

      assert {:ok, {:downloaded, _subtitle}} =
               Mydia.Subtitles.search_subtitles(media_file.id,
                 languages: "en",
                 auto_download: true
               )

      assert_received {:downloaded, "auto-download-match", "auto-1"}
      refute_received {:downloaded, "wrong", _}
    end
  end

  describe "normalize_format/1" do
    test "keeps a stated format" do
      assert Mydia.Subtitles.normalize_format(%{format: "ass"}) == "ass"
    end

    test "falls back to the file name's extension" do
      assert Mydia.Subtitles.normalize_format(%{format: nil, file_name: "Movie.ass"}) == "ass"
    end

    test "defaults to srt when it has nothing to go on" do
      assert Mydia.Subtitles.normalize_format(%{format: nil, file_name: nil}) == "srt"
      assert Mydia.Subtitles.normalize_format(%{}) == "srt"
    end
  end
end
