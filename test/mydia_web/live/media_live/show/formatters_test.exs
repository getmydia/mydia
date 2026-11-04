defmodule MydiaWeb.MediaLive.Show.FormattersTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.MediaLive.Show.Formatters

  describe "format_seeders/1" do
    test "counts under 10,000 are exact" do
      assert Formatters.format_seeders(0) == "0"
      assert Formatters.format_seeders(9_999) == "9999"
    end

    test "10,000 to 99,999 show one truncated decimal in thousands" do
      assert Formatters.format_seeders(10_000) == "10k"
      assert Formatters.format_seeders(12_345) == "12.3k"
      assert Formatters.format_seeders(99_999) == "99.9k"
    end

    test "100,000 to 999,999 show whole thousands" do
      assert Formatters.format_seeders(123_456) == "123k"
      assert Formatters.format_seeders(999_999) == "999k"
    end

    test "millions show one truncated decimal, then whole millions" do
      assert Formatters.format_seeders(1_000_000) == "1M"
      assert Formatters.format_seeders(1_250_000) == "1.2M"
      assert Formatters.format_seeders(12_345_678) == "12M"
    end
  end
end
