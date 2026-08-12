defmodule MetadataRelay.OpenSubtitles.HandlerTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.OpenSubtitles.Handler
  alias MetadataRelay.Test.OpenSubtitlesHelpers

  @moduletag :capture_log

  setup do
    # Set a test API key to avoid the missing key error
    System.put_env("OPENSUBTITLES_API_KEY", "test_api_key_12345")

    # Stand in for the real Auth GenServer (which would otherwise perform a
    # live login request) so Client.new/0 can obtain a token.
    auth_pid = OpenSubtitlesHelpers.start_stub_auth()

    on_exit(fn ->
      if Process.alive?(auth_pid), do: GenServer.stop(auth_pid)
      OpenSubtitlesHelpers.clear_opensubtitles_adapter()
      System.delete_env("OPENSUBTITLES_API_KEY")
    end)

    :ok
  end

  # A representative OpenSubtitles `/subtitles` search result entry. Only
  # `attributes` fields transform_subtitle/1 actually reads are populated;
  # `moviehash_match` is passed as an override so each test controls it.
  defp subtitle_fixture(attribute_overrides) do
    attributes =
      Map.merge(
        %{
          "language" => "en",
          "format" => "srt",
          "ratings" => 8.5,
          "download_count" => 100,
          "release" => "Test.Release.720p.WEB-DL",
          "uploader" => %{"name" => "someuser"},
          "hearing_impaired" => false,
          "foreign_parts_only" => false,
          "files" => [%{"file_id" => 12_345}],
          "feature_details" => %{
            "feature_type" => "Movie",
            "title" => "Test Movie",
            "year" => 2020,
            "imdb_id" => "0133093",
            "tmdb_id" => nil
          }
        },
        attribute_overrides
      )

    %{"id" => "9999", "attributes" => attributes}
  end

  describe "search/1 moviehash_match" do
    test "carries moviehash_match: true through when OpenSubtitles reports a match" do
      OpenSubtitlesHelpers.set_opensubtitles_adapter(
        OpenSubtitlesHelpers.mock_adapter_with_routes(%{
          "/subtitles" => {200, %{"data" => [subtitle_fixture(%{"moviehash_match" => true})]}}
        })
      )

      assert {:ok, %{"subtitles" => [subtitle]}} =
               Handler.search(%{
                 file_hash: "8e245d9679d31e12",
                 file_size: "742086656",
                 languages: "en"
               })

      assert subtitle["id"] == 12_345
      assert subtitle["moviehash_match"] == true
    end

    test "defaults moviehash_match to false when OpenSubtitles omits the key" do
      OpenSubtitlesHelpers.set_opensubtitles_adapter(
        OpenSubtitlesHelpers.mock_adapter_with_routes(%{
          "/subtitles" => {200, %{"data" => [subtitle_fixture(%{})]}}
        })
      )

      assert {:ok, %{"subtitles" => [subtitle]}} =
               Handler.search(%{imdb_id: "0133093", languages: "en"})

      assert subtitle["id"] == 12_345
      assert subtitle["moviehash_match"] == false
    end
  end
end
