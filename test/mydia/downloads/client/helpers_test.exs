defmodule Mydia.Downloads.Client.HelpersTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Helpers

  describe "redact_url/1" do
    test "strips credential-bearing query params" do
      redacted = Helpers.redact_url("https://example.com/f?token=ABC&safe=keep")

      refute redacted =~ "ABC"
      assert redacted =~ "safe=keep"
    end

    test "returns nil for nil" do
      assert Helpers.redact_url(nil) == nil
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
