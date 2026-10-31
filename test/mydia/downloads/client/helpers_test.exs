defmodule Mydia.Downloads.Client.HelpersTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Helpers

  describe "redact_params/1" do
    test "redacts credential values in a map or a pair list" do
      assert Helpers.redact_params(%{"q" => "invented", "passkey" => "feedface"}) ==
               %{"q" => "invented", "passkey" => "[REDACTED]"}

      assert Helpers.redact_params([{"apikey", "k1"}, {:cat, "2000"}]) ==
               [{"apikey", "[REDACTED]"}, {:cat, "2000"}]
    end

    test "catches credential-like names beyond the URL list, nested maps and form bodies" do
      assert Helpers.redact_params(%{
               "secret_key" => "s1",
               "api-key" => "s2",
               "torrentpass" => "s3",
               "nested" => %{"pin_pass" => "s4", "q" => "invented"}
             }) == %{
               "secret_key" => "[REDACTED]",
               "api-key" => "[REDACTED]",
               "torrentpass" => "[REDACTED]",
               "nested" => %{"pin_pass" => "[REDACTED]", "q" => "invented"}
             }

      assert Helpers.redact_params("q=invented&secret=s5") == "q=invented&secret=%5BREDACTED%5D"

      assert Helpers.redact_params([%{"passkey" => "s6", "q" => "invented"}]) ==
               [%{"passkey" => "[REDACTED]", "q" => "invented"}]
    end
  end

  describe "redact_urls_in/1" do
    test "keeps only the origin of every URL in nested metadata" do
      metadata = %{
        "quality" => "1080p",
        "seeders" => 12,
        "debrid_urls" => [
          %{"url" => "https://cdn.debrid.example.test/d/Q7KZ19/Invented.Feature.mkv"}
        ],
        "source" => "magnet:?xt=urn:btih:abc&tr=udp%3A%2F%2Fone.example"
      }

      assert Helpers.redact_urls_in(metadata) == %{
               "quality" => "1080p",
               "seeders" => 12,
               "debrid_urls" => [%{"url" => "https://cdn.debrid.example.test/…"}],
               "source" => "magnet:…"
             }
    end

    test "redacts URLs embedded in text and URI structs" do
      assert Helpers.redact_urls_in("see https://cdn.example.test/d/TOKEN99 here") ==
               "see https://cdn.example.test/… here"

      assert Helpers.redact_urls_in(URI.parse("https://cdn.example.test/d/TOKEN99")) ==
               "https://cdn.example.test/…"

      assert Helpers.redact_urls_in("Invented.Feature.2021 1080p") ==
               "Invented.Feature.2021 1080p"
    end
  end

  describe "redact_url/1" do
    test "strips credential-bearing query params" do
      redacted = Helpers.redact_url("https://example.com/f?token=ABC&safe=keep")

      refute redacted =~ "ABC"
      assert redacted =~ "safe=keep"
    end

    test "strips tracker passkeys, authkeys and rsskeys" do
      redacted =
        Helpers.redact_url(
          "https://tracker.example/dl.php?id=4&passkey=PK1&authkey=AK1&rsskey=RK1&torrent_pass=TP1"
        )

      for secret <- ~w(PK1 AK1 RK1 TP1), do: refute(redacted =~ secret)
      assert redacted =~ "id=4"
    end

    test "returns nil for nil" do
      assert Helpers.redact_url(nil) == nil
    end

    test "returns a magnet with repeated trackers byte for byte" do
      magnet =
        "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567" <>
          "&dn=Lantern+Harbor+S01E01" <>
          "&tr=udp%3A%2F%2Ftracker.one.example%3A1337%2Fannounce" <>
          "&tr=udp%3A%2F%2Ftracker.two.example%3A6969%2Fannounce"

      assert Helpers.redact_url(magnet) == magnet
    end

    test "keeps every repeated parameter when another one is redacted" do
      redacted =
        Helpers.redact_url(
          "magnet:?xt=urn:btih:aa&tr=udp%3A%2F%2Fone.example&tr=udp%3A%2F%2Ftwo.example&passkey=PK9"
        )

      assert redacted ==
               "magnet:?xt=urn:btih:aa&tr=udp%3A%2F%2Fone.example&tr=udp%3A%2F%2Ftwo.example" <>
                 "&passkey=%5BREDACTED%5D"
    end

    test "strips userinfo along with a passkey" do
      redacted =
        Helpers.redact_url(
          "https://orchard:HUNTER2@tracker.example/download.php?id=4&passkey=PK2#top"
        )

      assert redacted == "https://tracker.example/download.php?id=4&passkey=%5BREDACTED%5D#top"
    end

    test "strips userinfo from a URL with no query" do
      assert Helpers.redact_url("https://orchard:HUNTER2@tracker.example/rss") ==
               "https://tracker.example/rss"
    end

    # UNIT3D puts the account's rsskey in the path: /torrent/download/<id>.<key>.
    test "redacts a UNIT3D key after the torrent id in the path" do
      url = "https://tracker.example.test/torrent/download/48213.a1b2c3d4e5f60718293a4b5c6d7e8f90"

      assert Helpers.redact_url(url) ==
               "https://tracker.example.test/torrent/download/48213.%5BREDACTED%5D"
    end

    test "redacts a whole path segment that looks like a key" do
      url = "https://tracker.example.test/rss/Zq9xY7wV5uT3sR1pQ0oN8mL6kJ4h/download/77"

      assert Helpers.redact_url(url) ==
               "https://tracker.example.test/rss/%5BREDACTED%5D/download/77"
    end

    test "redacts Gazelle query credentials and keeps the path" do
      url =
        "https://tracker.example.test/torrents.php?action=download&id=991&authkey=ak77&torrent_pass=tp88"

      redacted = Helpers.redact_url(url)

      assert redacted =~ "https://tracker.example.test/torrents.php?action=download&id=991"
      refute redacted =~ "ak77"
      refute redacted =~ "tp88"
    end

    test "keeps numeric ids, ordinary slugs and short tokens in a public URL" do
      for url <- [
            "https://indexer.example.test/download/123456789012345678901234567890.torrent",
            "https://indexer.example.test/details/invented-feature-2021-1080p-bluray-x264",
            "https://indexer.example.test/releases/Invented_Feature_2021_1080p_BluRay/a1b2"
          ] do
        assert Helpers.redact_url(url) == url
      end
    end

    test "leaves a magnet byte for byte" do
      magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Invented"
      assert Helpers.redact_url(magnet) == magnet
    end

    test "redacts a path key whose characters were percent-encoded" do
      url =
        "https://tracker.example.test/torrent/download/48213.a1b2c3d4e5f6%30718293a4b5c6d7e8f90"

      assert Helpers.redact_url(url) ==
               "https://tracker.example.test/torrent/download/48213.%5BREDACTED%5D"
    end

    test "redacts a path key behind an encoded dot" do
      url =
        "https://tracker.example.test/torrent/download/48213%2Ea1b2c3d4e5f60718293a4b5c6d7e8f90"

      assert Helpers.redact_url(url) ==
               "https://tracker.example.test/torrent/download/48213%2E%5BREDACTED%5D"
    end

    test "leaves free text without a host alone" do
      text = "statusCode 503 upstream_unavailable_after_retry_2"
      assert Helpers.redact_url(text) == text
    end
  end

  describe "sanitize_failure_detail/1" do
    test "passes an ordinary provider token through untouched" do
      assert Helpers.sanitize_failure_detail("missingFiles") == "missingFiles"
    end

    test "redacts a credential that leaked into the detail" do
      detail = Helpers.sanitize_failure_detail("https://cdn.example.com/x?token=SECRET")

      refute detail =~ "SECRET"
    end

    test "truncates to 200 characters" do
      detail = Helpers.sanitize_failure_detail(String.duplicate("a", 500))

      assert String.length(detail) == 200
    end

    test "leaves a detail of exactly 200 characters alone" do
      input = String.duplicate("b", 200)

      assert Helpers.sanitize_failure_detail(input) == input
    end

    test "returns nil for nil" do
      assert Helpers.sanitize_failure_detail(nil) == nil
    end
  end
end
