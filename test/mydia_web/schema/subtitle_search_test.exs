defmodule MydiaWeb.Schema.SubtitleSearchTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures

  @search """
  query SubtitleSearch($mediaFileId: ID!, $languages: [String!]!) {
    subtitleSearch(mediaFileId: $mediaFileId, languages: $languages) {
      results {
        token
        language
        releaseName
        format
        rating
        downloadCount
        hearingImpaired
        hashMatch
        score
        providerName
      }
      providers {
        name
        quotaRemaining
        quotaTotal
        error
      }
    }
  }
  """

  @download """
  mutation DownloadSubtitle($mediaFileId: ID!, $token: String!) {
    downloadSubtitle(mediaFileId: $mediaFileId, token: $token) {
      trackId
      language
      format
      embedded
      deliverable
    }
  }
  """

  defmodule StubAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_provider, _params) do
      {:ok,
       [
         %Mydia.Subtitles.Provider.SearchResult{
           file_id: 12_345,
           language: "en",
           format: "srt",
           subtitle_hash: "abc123",
           file_name: "Movie.2020.1080p.BluRay.srt",
           rating: 8.5,
           download_count: 4200,
           hearing_impaired: false,
           moviehash_match: true
         }
       ]}
    end

    @impl true
    def download(_provider, _info), do: {:ok, "https://example.com/sub.srt"}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_provider),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:relay)}

    @impl true
    def capabilities do
      %{
        media_types: [:movie, :episode],
        search_keys: [:file_hash, :imdb_id, :tmdb_id, :query],
        requires_credentials: false,
        quota: :unlimited
      }
    end
  end

  setup %{conn: conn} do
    # Injected per config row rather than through application environment, which
    # would leak across concurrently running tests.
    Mydia.SubtitleProviderFixtures.stub_registry_adapter(:relay, StubAdapter)

    user = AccountsFixtures.user_fixture()
    movie = MediaFixtures.media_item_fixture(%{type: "movie", imdb_id: "0133093"})
    media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

    {:ok, conn: log_in_user(conn, user), media_file: media_file}
  end

  defp gql(conn, query, variables) do
    conn
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  test "returns scored candidates with signed tokens", %{conn: conn, media_file: media_file} do
    body =
      gql(conn, @search, %{"mediaFileId" => media_file.id, "languages" => ["en"]})

    %{"data" => %{"subtitleSearch" => payload}} = body
    assert [result] = payload["results"]

    assert result["language"] == "en"
    assert result["releaseName"] == "Movie.2020.1080p.BluRay.srt"
    assert result["hashMatch"] == true
    assert result["score"] > 0
    assert is_binary(result["token"]) and result["token"] != ""

    assert [provider] = payload["providers"]
    assert provider["error"] == nil
  end

  test "rejects a token issued for another media file", %{conn: conn, media_file: media_file} do
    %{"data" => %{"subtitleSearch" => %{"results" => [result]}}} =
      gql(conn, @search, %{"mediaFileId" => media_file.id, "languages" => ["en"]})

    other = MediaFixtures.media_file_fixture()

    body = gql(conn, @download, %{"mediaFileId" => other.id, "token" => result["token"]})

    assert %{"errors" => [%{"message" => message}]} = body
    assert message =~ "expired" or message =~ "not valid"
  end

  test "rejects a tampered token", %{conn: conn, media_file: media_file} do
    body =
      gql(conn, @download, %{"mediaFileId" => media_file.id, "token" => "garbage"})

    assert %{"errors" => [_ | _]} = body
  end

  test "requires authentication", %{media_file: media_file} do
    body =
      build_conn()
      |> post("/api/graphql", %{
        "query" => @search,
        "variables" => %{"mediaFileId" => media_file.id, "languages" => ["en"]}
      })
      |> json_response(200)

    assert %{"errors" => [_ | _]} = body
  end
end
