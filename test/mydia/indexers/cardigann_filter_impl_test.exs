defmodule Mydia.Indexers.CardigannFilterImplTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannResultParser

  # Helper to apply a single filter via the public apply_filters API
  defp apply_filter(value, filter) do
    CardigannResultParser.apply_filters(value, [filter], %{})
  end

  describe "regexp filter" do
    test "accepts a .NET \\u escape" do
      pattern = ~S"(\d{4}/\d{1,2}/\d{1,2}[\s\u00A0]+\d{1,2}:\d{2})"

      assert {:ok, "2026/10/27 12:00"} =
               apply_filter("2026/10/27 12:00 in four days", %{name: "regexp", args: [pattern]})
    end

    test "extracts first capture group" do
      assert {:ok, "123"} = apply_filter("abc123def", %{name: "regexp", args: ["(\\d+)"]})
    end

    test "returns empty string when no match" do
      assert {:ok, ""} = apply_filter("abc", %{name: "regexp", args: ["(\\d+)"]})
    end

    test "returns only first capture group when multiple groups exist" do
      assert {:ok, "hello"} =
               apply_filter("hello world", %{name: "regexp", args: ["(\\w+)\\s+(\\w+)"]})
    end

    test "returns empty string when pattern has no capture group" do
      assert {:ok, ""} = apply_filter("hello", %{name: "regexp", args: ["\\w+"]})
    end

    test "works with string-keyed filter" do
      assert {:ok, "42"} =
               apply_filter("size: 42 MB", %{"name" => "regexp", "args" => ["(\\d+)"]})
    end

    test "works with single string arg (not in list)" do
      assert {:ok, "42"} =
               apply_filter("size: 42 MB", %{name: "regexp", args: "(\\d+)"})
    end

    test "handles complex extraction patterns" do
      assert {:ok, "1234"} =
               apply_filter(
                 "https://example.com/torrent/1234/download",
                 %{name: "regexp", args: ["/torrent/(\\d+)/"]}
               )
    end
  end

  describe "dateparse/timeparse filter" do
    test "parses date with Go layout format" do
      assert {:ok, result} =
               apply_filter("2024-01-15", %{name: "dateparse", args: ["2006-01-02"]})

      assert String.contains?(result, "2024-01-15")
    end

    test "parses date with time" do
      assert {:ok, result} =
               apply_filter(
                 "2024-01-15 14:30:00",
                 %{name: "dateparse", args: ["2006-01-02 15:04:05"]}
               )

      assert String.contains?(result, "2024-01-15")
      assert String.contains?(result, "14:30:00")
    end

    test "parses abbreviated month format" do
      assert {:ok, result} =
               apply_filter("15 Jan 2024", %{name: "dateparse", args: ["02 Jan 2006"]})

      assert String.contains?(result, "2024-01-15")
    end

    test "parses an RFC 1123 date written as a .NET layout" do
      assert {:ok, "2031-01-03T01:27:58Z"} =
               apply_filter(
                 "Sat, 03 Jan 2031 01:27:58 +00:00",
                 %{name: "dateparse", args: "ddd, dd MMM yyyy HH:mm:ss zzz"}
               )
    end

    test "parses a short .NET layout with a one digit day and a two digit year" do
      assert {:ok, "2026-10-12T00:00:00+03:00"} =
               apply_filter("12 Oct 26 +03:00", %{name: "dateparse", args: "d MMM yy zzz"})
    end

    test "treats a non-breaking space in the value as a space" do
      assert {:ok, "2026-10-12T00:00:00+03:00"} =
               apply_filter("12\u00A0Oct\u00A026 +03:00", %{
                 name: "dateparse",
                 args: "d MMM yy zzz"
               })
    end

    test "parses a .NET layout with no separator before the time" do
      assert {:ok, "2031-02-03T04:05:06Z"} =
               apply_filter("2031-02-0304:05:06", %{
                 name: "dateparse",
                 args: "yyyy-MM-ddHH:mm:ss"
               })
    end

    test "timeparse is an alias for dateparse" do
      assert {:ok, result} =
               apply_filter("2024-01-15", %{name: "timeparse", args: ["2006-01-02"]})

      assert String.contains?(result, "2024-01-15")
    end

    test "returns original value on parse failure" do
      assert {:ok, "not-a-date"} =
               apply_filter("not-a-date", %{name: "dateparse", args: ["2006-01-02"]})
    end

    test "works with string-keyed filter" do
      assert {:ok, result} =
               apply_filter(
                 "2024-01-15",
                 %{"name" => "dateparse", "args" => ["2006-01-02"]}
               )

      assert String.contains?(result, "2024-01-15")
    end

    test "works with single string arg (not in list)" do
      assert {:ok, result} =
               apply_filter("2024-01-15", %{name: "dateparse", args: "2006-01-02"})

      assert String.contains?(result, "2024-01-15")
    end
  end

  describe "timeago/reltime filter" do
    test "parses hours ago" do
      assert {:ok, result} = apply_filter("2 hours ago", %{name: "timeago"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      # Should be approximately 2 hours ago (within 5 seconds of tolerance)
      diff = DateTime.diff(now, dt, :second)
      assert_in_delta diff, 7200, 5
    end

    test "parses minutes ago" do
      assert {:ok, result} = apply_filter("30 minutes ago", %{name: "timeago"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, dt, :second)
      assert_in_delta diff, 1800, 5
    end

    test "parses days ago" do
      assert {:ok, result} = apply_filter("3 days ago", %{name: "reltime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, dt, :second)
      assert_in_delta diff, 259_200, 5
    end

    test "parses compound time expressions" do
      assert {:ok, result} = apply_filter("1 day 2 hours ago", %{name: "timeago"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, dt, :second)
      assert_in_delta diff, 93_600, 5
    end

    test "parses 'now'" do
      assert {:ok, result} = apply_filter("now", %{name: "timeago"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      diff = abs(DateTime.diff(now, dt, :second))
      assert diff < 5
    end

    test "handles abbreviated units" do
      assert {:ok, result} = apply_filter("5m ago", %{name: "timeago"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, dt, :second)
      assert_in_delta diff, 300, 5
    end

    test "works with string-keyed filter" do
      assert {:ok, result} = apply_filter("1 hour ago", %{"name" => "reltime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, dt, :second)
      assert_in_delta diff, 3600, 5
    end
  end

  describe "fuzzytime filter" do
    test "parses unix timestamp (seconds)" do
      # 2024-01-15T00:00:00Z
      assert {:ok, result} = apply_filter("1705276800", %{name: "fuzzytime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      assert dt.year == 2024
      assert dt.month == 1
      assert dt.day == 15
    end

    test "parses unix timestamp (milliseconds)" do
      assert {:ok, result} = apply_filter("1705276800000", %{name: "fuzzytime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      assert dt.year == 2024
      assert dt.month == 1
      assert dt.day == 15
    end

    test "parses 'now'" do
      assert {:ok, result} = apply_filter("now", %{name: "fuzzytime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      assert abs(DateTime.diff(now, dt, :second)) < 5
    end

    test "parses 'X ago' patterns" do
      assert {:ok, result} = apply_filter("2 hours ago", %{name: "fuzzytime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, dt, :second)
      assert_in_delta diff, 7200, 5
    end

    test "parses 'Today HH:MM'" do
      assert {:ok, result} = apply_filter("Today 14:30", %{name: "fuzzytime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      today = DateTime.utc_now() |> DateTime.to_date()
      assert Date.compare(DateTime.to_date(dt), today) == :eq
      assert dt.hour == 14
      assert dt.minute == 30
    end

    test "parses 'Yesterday HH:MM'" do
      assert {:ok, result} = apply_filter("Yesterday 10:00", %{name: "fuzzytime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      yesterday = DateTime.utc_now() |> DateTime.to_date() |> Date.add(-1)
      assert Date.compare(DateTime.to_date(dt), yesterday) == :eq
      assert dt.hour == 10
      assert dt.minute == 0
    end

    test "returns original value on failure" do
      assert {:ok, "not parseable at all xyz"} =
               apply_filter("not parseable at all xyz", %{name: "fuzzytime"})
    end

    test "works with string-keyed filter" do
      assert {:ok, result} = apply_filter("1705276800", %{"name" => "fuzzytime"})
      {:ok, dt, _} = DateTime.from_iso8601(result)
      assert dt.year == 2024
    end
  end

  describe "tolower filter" do
    test "converts to lowercase" do
      assert {:ok, "hello world"} = apply_filter("Hello World", %{name: "tolower"})
    end

    test "handles already lowercase" do
      assert {:ok, "hello"} = apply_filter("hello", %{name: "tolower"})
    end

    test "handles empty string" do
      assert {:ok, ""} = apply_filter("", %{name: "tolower"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "abc"} = apply_filter("ABC", %{"name" => "tolower"})
    end
  end

  describe "toupper filter" do
    test "converts to uppercase" do
      assert {:ok, "HELLO WORLD"} = apply_filter("Hello World", %{name: "toupper"})
    end

    test "handles already uppercase" do
      assert {:ok, "HELLO"} = apply_filter("HELLO", %{name: "toupper"})
    end

    test "handles empty string" do
      assert {:ok, ""} = apply_filter("", %{name: "toupper"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "ABC"} = apply_filter("abc", %{"name" => "toupper"})
    end
  end

  describe "urlencode filter" do
    test "encodes spaces" do
      assert {:ok, "hello+world"} = apply_filter("hello world", %{name: "urlencode"})
    end

    test "encodes special characters" do
      assert {:ok, result} = apply_filter("foo&bar=baz", %{name: "urlencode"})
      assert result == "foo%26bar%3Dbaz"
    end

    test "leaves alphanumeric unchanged" do
      assert {:ok, "abc123"} = apply_filter("abc123", %{name: "urlencode"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "a+b"} = apply_filter("a b", %{"name" => "urlencode"})
    end
  end

  describe "htmldecode filter" do
    test "decodes &amp;" do
      assert {:ok, "AT&T"} = apply_filter("AT&amp;T", %{name: "htmldecode"})
    end

    test "decodes &lt; and &gt;" do
      assert {:ok, "<div>"} = apply_filter("&lt;div&gt;", %{name: "htmldecode"})
    end

    test "decodes &quot;" do
      assert {:ok, ~s(say "hello")} =
               apply_filter("say &quot;hello&quot;", %{name: "htmldecode"})
    end

    test "decodes &#39; (numeric apostrophe)" do
      assert {:ok, "it's"} = apply_filter("it&#39;s", %{name: "htmldecode"})
    end

    test "decodes &apos;" do
      assert {:ok, "it's"} = apply_filter("it&apos;s", %{name: "htmldecode"})
    end

    test "decodes numeric decimal entities" do
      assert {:ok, "A"} = apply_filter("&#65;", %{name: "htmldecode"})
    end

    test "decodes numeric hex entities" do
      assert {:ok, "A"} = apply_filter("&#x41;", %{name: "htmldecode"})
    end

    test "decodes &nbsp;" do
      assert {:ok, "hello world"} = apply_filter("hello&nbsp;world", %{name: "htmldecode"})
    end

    test "passes through already-decoded strings" do
      assert {:ok, "hello world"} = apply_filter("hello world", %{name: "htmldecode"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "A&B"} = apply_filter("A&amp;B", %{"name" => "htmldecode"})
    end
  end

  describe "querystring filter" do
    test "extracts parameter from URL" do
      url = "https://example.com/search?q=hello&page=1"
      assert {:ok, "hello"} = apply_filter(url, %{name: "querystring", args: ["q"]})
    end

    test "extracts second parameter" do
      url = "https://example.com/search?q=hello&page=2"
      assert {:ok, "2"} = apply_filter(url, %{name: "querystring", args: ["page"]})
    end

    test "returns empty string for missing parameter" do
      url = "https://example.com/search?q=hello"
      assert {:ok, ""} = apply_filter(url, %{name: "querystring", args: ["missing"]})
    end

    test "decodes URL-encoded parameter values" do
      url = "https://example.com/search?q=hello+world&cat=TV%20Shows"
      assert {:ok, "hello world"} = apply_filter(url, %{name: "querystring", args: ["q"]})
    end

    test "works with string-keyed filter" do
      url = "https://example.com?id=42"
      assert {:ok, "42"} = apply_filter(url, %{"name" => "querystring", "args" => ["id"]})
    end

    test "works with single string arg (not in list)" do
      url = "https://example.com?id=42"
      assert {:ok, "42"} = apply_filter(url, %{name: "querystring", args: "id"})
    end
  end

  describe "filter chaining" do
    test "chains multiple filters in sequence" do
      filters = [
        %{name: "trim"},
        %{name: "tolower"},
        %{name: "replace", args: [" ", "-"]}
      ]

      assert {:ok, "hello-world"} =
               CardigannResultParser.apply_filters("  Hello World  ", filters, %{})
    end

    test "chains regexp with append" do
      filters = [
        %{name: "regexp", args: ["(\\d+)"]},
        %{name: "append", args: [" MB"]}
      ]

      assert {:ok, "42 MB"} =
               CardigannResultParser.apply_filters("Size: 42 bytes", filters, %{})
    end

    test "chains htmldecode with trim" do
      filters = [
        %{name: "htmldecode"},
        %{name: "trim"}
      ]

      assert {:ok, "Tom & Jerry"} =
               CardigannResultParser.apply_filters("  Tom &amp; Jerry  ", filters, %{})
    end
  end

  describe "go_layout_to_strftime conversion" do
    # Test the conversion via dateparse filter behavior
    test "handles ISO date format" do
      assert {:ok, result} =
               apply_filter("2024-03-15", %{name: "dateparse", args: ["2006-01-02"]})

      assert String.contains?(result, "2024-03-15")
    end

    test "handles datetime with timezone" do
      assert {:ok, result} =
               apply_filter(
                 "2024-03-15T10:30:00Z",
                 %{name: "dateparse", args: ["2006-01-02T15:04:05Z07:00"]}
               )

      assert String.contains?(result, "2024-03-15")
    end

    test "handles month name format" do
      assert {:ok, result} =
               apply_filter("January 15, 2024", %{name: "dateparse", args: ["January 02, 2006"]})

      assert String.contains?(result, "2024-01-15")
    end

    test "handles 12-hour time with AM/PM" do
      assert {:ok, result} =
               apply_filter(
                 "01/15/2024 02:30 PM",
                 %{name: "dateparse", args: ["01/02/2006 03:04 PM"]}
               )

      assert String.contains?(result, "2024-01-15")
      assert String.contains?(result, "14:30")
    end
  end

  describe "validfilename filter" do
    test "strips invalid filename characters" do
      assert {:ok, "filename.txt"} =
               apply_filter("file<>name.txt", %{name: "validfilename"})
    end

    test "strips colons and pipes" do
      assert {:ok, "movie title  2024"} =
               apply_filter("movie: title | 2024", %{name: "validfilename"})
    end

    test "strips question marks and asterisks" do
      assert {:ok, "is this real"} =
               apply_filter("is this real?*", %{name: "validfilename"})
    end

    test "preserves valid characters" do
      assert {:ok, "normal-file_name (2024).mkv"} =
               apply_filter("normal-file_name (2024).mkv", %{name: "validfilename"})
    end

    test "trims whitespace" do
      assert {:ok, "test"} =
               apply_filter("  test  ", %{name: "validfilename"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "abc"} = apply_filter("a<b>c", %{"name" => "validfilename"})
    end
  end

  describe "diacritics filter" do
    test "removes accents from characters" do
      assert {:ok, "cafe"} = apply_filter("caf\u00E9", %{name: "diacritics"})
    end

    test "removes umlauts" do
      assert {:ok, "uber"} = apply_filter("\u00FCber", %{name: "diacritics"})
    end

    test "handles multiple diacritics" do
      assert {:ok, "Zurich"} = apply_filter("Z\u00FCrich", %{name: "diacritics"})
    end

    test "preserves plain ASCII" do
      assert {:ok, "hello world"} = apply_filter("hello world", %{name: "diacritics"})
    end

    test "removes cedilla" do
      assert {:ok, "francais"} = apply_filter("fran\u00E7ais", %{name: "diacritics"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "cafe"} = apply_filter("caf\u00E9", %{"name" => "diacritics"})
    end
  end

  describe "jsonjoinarray filter" do
    test "joins array at root path" do
      json = Jason.encode!(["action", "thriller", "drama"])

      assert {:ok, "action, thriller, drama"} =
               apply_filter(json, %{name: "jsonjoinarray", args: ["$", ", "]})
    end

    test "joins array at nested path" do
      json = Jason.encode!(%{"genres" => ["action", "thriller"]})

      assert {:ok, "action, thriller"} =
               apply_filter(json, %{name: "jsonjoinarray", args: ["$.genres", ", "]})
    end

    test "uses custom separator" do
      json = Jason.encode!(["a", "b", "c"])

      assert {:ok, "a|b|c"} =
               apply_filter(json, %{name: "jsonjoinarray", args: ["$", "|"]})
    end

    test "returns original value for invalid JSON" do
      assert {:ok, "not json"} =
               apply_filter("not json", %{name: "jsonjoinarray", args: ["$", ", "]})
    end

    test "returns single value for non-array" do
      json = Jason.encode!(%{"name" => "test"})

      assert {:ok, "test"} =
               apply_filter(json, %{name: "jsonjoinarray", args: ["$.name", ", "]})
    end

    test "works with string-keyed filter" do
      json = Jason.encode!(["a", "b"])

      assert {:ok, "a, b"} =
               apply_filter(json, %{"name" => "jsonjoinarray", "args" => ["$", ", "]})
    end
  end

  describe "strdump filter" do
    test "passes value through unchanged" do
      assert {:ok, "test value"} = apply_filter("test value", %{name: "strdump"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "abc"} = apply_filter("abc", %{"name" => "strdump"})
    end
  end

  describe "hexdump filter" do
    test "passes value through unchanged" do
      assert {:ok, "test value"} = apply_filter("test value", %{name: "hexdump"})
    end

    test "works with string-keyed filter" do
      assert {:ok, "abc"} = apply_filter("abc", %{"name" => "hexdump"})
    end
  end

  describe "numeric filter args" do
    alias Mydia.Indexers.CardigannFilters

    # kickasstorrents-ws.yml uses `replace` with args ["N/A", 0]; YAML decodes the 0 as an integer.
    test "replace accepts an integer replacement (string-keyed)" do
      assert {:ok, "0"} =
               CardigannFilters.apply(%{"name" => "replace", "args" => ["N/A", 0]}, "N/A")
    end

    test "replace accepts an integer replacement (atom-keyed)" do
      assert {:ok, "0"} = CardigannFilters.apply(%{name: "replace", args: ["N/A", 0]}, "N/A")
    end

    test "append accepts an integer arg" do
      assert {:ok, "x1"} = CardigannFilters.apply(%{name: "append", args: [1]}, "x")
    end

    test "append accepts a single non-list integer arg" do
      assert {:ok, "x1"} = CardigannFilters.apply(%{name: "append", args: 1}, "x")
    end
  end
end
