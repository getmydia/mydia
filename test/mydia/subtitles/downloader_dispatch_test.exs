defmodule Mydia.Subtitles.DownloaderDispatchTest do
  use Mydia.DataCase, async: true

  alias Mydia.MediaFixtures
  alias Mydia.Subtitles.Downloader

  @srt "1\n00:00:01,000 --> 00:00:02,000\nhi\n"

  defmodule ContentAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_config, _params), do: {:ok, []}

    # Returns the subtitle body, which is the behaviour's contract. Any archive
    # unwrapping is the adapter's own business and has already happened by now.
    @impl true
    def download(_config, _info), do: {:ok, "1\n00:00:01,000 --> 00:00:02,000\nhi\n"}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_config),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:subdl)}

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

  defmodule FailingAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_config, _params), do: {:ok, []}

    @impl true
    def download(_config, _info), do: {:error, :no_subtitle_in_archive}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_config),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:subdl)}

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

  defmodule AssAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_config, _params), do: {:ok, []}

    # What SubDL and the relay actually serve for a result whose search entry
    # said "srt": the archive holds an ASS file.
    @impl true
    def download(_config, _info),
      do: {:ok, "[Script Info]\r\nScriptType: v4.00+\r\n\r\n[V4+ Styles]\r\nFormat: Name\r\n"}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_config),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:subdl)}

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

  defmodule GarbageAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_config, _params), do: {:ok, []}

    @impl true
    def download(_config, _info), do: {:ok, "<!DOCTYPE html><html>404</html>"}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_config),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:subdl)}

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

  setup do
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})
    media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

    {:ok, media_file: media_file}
  end

  defp config_for(adapter) do
    %{type: :subdl, connection_settings: %{"adapter" => adapter}}
  end

  test "writes the adapter's content to disk and records the provider", %{
    media_file: media_file
  } do
    info = %{
      file_id: "/subtitle/1.zip",
      language: "en",
      format: "srt",
      subtitle_hash: "content-hash"
    }

    assert {:ok, subtitle} =
             Downloader.download(info, media_file.id,
               provider_type: :subdl,
               provider_config: config_for(ContentAdapter)
             )

    assert subtitle.provider == "subdl"
    assert File.read!(subtitle.file_path) == @srt
  end

  test "propagates an adapter failure without writing anything", %{media_file: media_file} do
    info = %{
      file_id: "/subtitle/2.zip",
      language: "en",
      format: "srt",
      subtitle_hash: "failing-hash"
    }

    assert {:error, {:download_failed, :no_subtitle_in_archive}} =
             Downloader.download(info, media_file.id,
               provider_type: :subdl,
               provider_config: config_for(FailingAdapter)
             )
  end

  test "an ASS body declared as srt is stored as ass", %{media_file: media_file} do
    info = %{
      file_id: "/subtitle/3.zip",
      language: "en",
      format: "srt",
      subtitle_hash: "ass-hash"
    }

    assert {:ok, subtitle} =
             Downloader.download(info, media_file.id,
               provider_type: :subdl,
               provider_config: config_for(AssAdapter)
             )

    assert subtitle.format == "ass"
    assert String.ends_with?(subtitle.file_path, ".en.ass")
    assert File.exists?(subtitle.file_path)
  end

  test "content that is not a subtitle is rejected and leaves no file", %{
    media_file: media_file
  } do
    info = %{
      file_id: "/subtitle/4.zip",
      language: "en",
      format: "srt",
      subtitle_hash: "garbage-hash"
    }

    assert {:error, :unrecognized_subtitle_content} =
             Downloader.download(info, media_file.id,
               provider_type: :subdl,
               provider_config: config_for(GarbageAdapter)
             )

    assert Mydia.Subtitles.list_subtitles(media_file.id) == []
  end
end
