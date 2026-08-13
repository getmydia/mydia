defmodule MetadataRelay.SubDL.HandlerTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.SubDL.FileId
  alias MetadataRelay.SubDL.Handler

  @moduletag :capture_log

  setup do
    System.put_env("SUBDL_API_KEY", "test_key")

    on_exit(fn ->
      System.delete_env("SUBDL_API_KEY")
      Application.delete_env(:metadata_relay, :subdl_http_adapter)
    end)

    :ok
  end

  defp stub(fun), do: Application.put_env(:metadata_relay, :subdl_http_adapter, fun)

  # Captured from a live api.subdl.com response. Field names are SubDL's, not
  # the ones the relay emits.
  defp subtitle_fixture do
    %{
      "release_name" => "Matrix (1999) DVD.US.Retail",
      "name" => "Matrix (1999) DVD.US.Retail.zip",
      "lang" => "English",
      "author" => "Andurach",
      "url" => "/subtitle/3602674-8520054.zip?api_key=secret_key_value",
      "subtitlePage" => "/s/info/g2B1Xv4pU5",
      "season" => 0,
      "episode" => nil,
      "language" => "EN",
      "hi" => false
    }
  end

  test "translates a SubDL result into the relay's wire format" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{"status" => true, "subtitles" => [subtitle_fixture()]}
       )}
    end)

    assert {:ok, %{"subtitles" => [subtitle]}} =
             Handler.search(%{imdb_id: "0133093", languages: "en", media_type: "movie"})

    assert subtitle["language"] == "en"
    assert subtitle["release"] == "Matrix (1999) DVD.US.Retail"
    assert subtitle["format"] == "srt"
    assert subtitle["moviehash_match"] == false
    assert subtitle["hearing_impaired"] == false
    assert {:ok, "/subtitle/3602674-8520054.zip"} = FileId.decode(subtitle["id"])
  end

  test "never leaks the api key into the emitted id" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{"status" => true, "subtitles" => [subtitle_fixture()]}
       )}
    end)

    assert {:ok, %{"subtitles" => [subtitle]}} = Handler.search(%{imdb_id: "0133093"})
    refute Base.url_decode64!(subtitle["id"], padding: false) =~ "secret_key_value"
  end

  test "sends an imdb id with the tt prefix SubDL expects" do
    stub(fn request ->
      assert request.url.query =~ "imdb_id=tt0133093"
      {request, Req.Response.new(status: 200, body: %{"status" => true, "subtitles" => []})}
    end)

    assert {:ok, %{"subtitles" => []}} = Handler.search(%{imdb_id: "0133093"})
  end

  test "prefers a tmdb id and upcases languages" do
    stub(fn request ->
      assert request.url.query =~ "tmdb_id=603"
      assert request.url.query =~ "languages=EN%2CES"
      refute request.url.query =~ "imdb_id"
      {request, Req.Response.new(status: 200, body: %{"status" => true, "subtitles" => []})}
    end)

    assert {:ok, _} = Handler.search(%{tmdb_id: 603, imdb_id: "0133093", languages: "en,es"})
  end

  test "maps an episode search onto SubDL's tv parameters" do
    stub(fn request ->
      assert request.url.query =~ "type=tv"
      assert request.url.query =~ "season_number=2"
      assert request.url.query =~ "episode_number=5"
      {request, Req.Response.new(status: 200, body: %{"status" => true, "subtitles" => []})}
    end)

    assert {:ok, _} =
             Handler.search(%{
               tmdb_id: 1399,
               media_type: "episode",
               season_number: 2,
               episode_number: 5
             })
  end

  # SubDL reports a miss as status false with an error string. That is a search
  # that found nothing, not a failure, and must not read as a provider outage.
  test "treats a SubDL miss as an empty result" do
    stub(fn request ->
      {request, Req.Response.new(status: 200, body: %{"status" => false, "error" => "not found"})}
    end)

    assert {:ok, %{"subtitles" => []}} = Handler.search(%{imdb_id: "0133093"})
  end

  test "reports a search with no usable identity" do
    assert {:error, :insufficient_search_criteria} = Handler.search(%{languages: "en"})
  end

  test "passes the not-configured error through" do
    System.delete_env("SUBDL_API_KEY")

    assert {:error, :not_configured} = Handler.search(%{imdb_id: "0133093"})
  end

  test "does not leak api key when logging unexpected response" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "status" => true,
           "subtitles" => "not a list",
           "url" => "/subtitle/test.zip?api_key=secret_key_value"
         }
       )}
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, %{"subtitles" => []}} = Handler.search(%{imdb_id: "0133093"})
      end)

    refute log =~ "secret_key_value"
  end

  test "normalizes language from lang field when language is absent" do
    stub(fn request ->
      subtitle = subtitle_fixture() |> Map.delete("language")

      {request,
       Req.Response.new(
         status: 200,
         body: %{"status" => true, "subtitles" => [subtitle], "results" => []}
       )}
    end)

    assert {:ok, %{"subtitles" => [subtitle]}} =
             Handler.search(%{imdb_id: "0133093"})

    assert subtitle["language"] == "en"
  end

  test "defaults to en language when both language and lang are absent" do
    stub(fn request ->
      subtitle =
        subtitle_fixture()
        |> Map.delete("language")
        |> Map.delete("lang")

      {request,
       Req.Response.new(
         status: 200,
         body: %{"status" => true, "subtitles" => [subtitle], "results" => []}
       )}
    end)

    assert {:ok, %{"subtitles" => [subtitle]}} =
             Handler.search(%{imdb_id: "0133093"})

    assert subtitle["language"] == "en"
  end

  test "populates feature context keys from results array" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "status" => true,
           "subtitles" => [subtitle_fixture()],
           "results" => [
             %{
               "type" => "movie",
               "name" => "The Matrix",
               "year" => 1999,
               "imdb_id" => "tt0133093",
               "tmdb_id" => 603
             }
           ]
         }
       )}
    end)

    assert {:ok, %{"subtitles" => [subtitle]}} =
             Handler.search(%{imdb_id: "0133093"})

    assert subtitle["feature_type"] == "movie"
    assert subtitle["title"] == "The Matrix"
    assert subtitle["year"] == 1999
    assert subtitle["imdb_id"] == "tt0133093"
    assert subtitle["tmdb_id"] == 603
  end

  test "emits nil for feature context keys when results is empty" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{"status" => true, "subtitles" => [subtitle_fixture()], "results" => []}
       )}
    end)

    assert {:ok, %{"subtitles" => [subtitle]}} =
             Handler.search(%{imdb_id: "0133093"})

    assert is_nil(subtitle["feature_type"])
    assert is_nil(subtitle["title"])
    assert is_nil(subtitle["year"])
    assert is_nil(subtitle["imdb_id"])
    assert is_nil(subtitle["tmdb_id"])
  end

  test "handles non-map response bodies without crashing" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: "<html>Captcha challenge api_key=secret_key_value</html>"
       )}
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{"subtitles" => []}} = Handler.search(%{imdb_id: "0133093"})
      end)

    refute log =~ "secret_key_value"
  end

  test "handles malformed results array without crashing" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "status" => true,
           "subtitles" => [subtitle_fixture()],
           "results" => ["not", "a", "map"]
         }
       )}
    end)

    assert {:ok, %{"subtitles" => [subtitle]}} =
             Handler.search(%{imdb_id: "0133093"})

    assert is_nil(subtitle["feature_type"])
    assert is_nil(subtitle["title"])
  end
end
