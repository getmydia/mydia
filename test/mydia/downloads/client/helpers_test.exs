defmodule Mydia.Downloads.Client.HelpersTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Helpers

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
