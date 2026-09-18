defmodule MydiaWeb.FormattersTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.Formatters

  describe "format_file_size/1" do
    test "renders each tier" do
      assert Formatters.format_file_size(0) == "0 B"
      assert Formatters.format_file_size(512) == "512 B"
      assert Formatters.format_file_size(1024) == "1.0 KB"
      assert Formatters.format_file_size(1_048_576) == "1.0 MB"
      assert Formatters.format_file_size(1_073_741_824) == "1.0 GB"
      assert Formatters.format_file_size(1_099_511_627_776) == "1.0 TB"
    end

    test "a multi-terabyte library reads in terabytes, not thousands of gigabytes" do
      assert Formatters.format_file_size(6_840_000_000_000) == "6.22 TB"
    end

    test "an unknown size renders the dash, not a crash" do
      assert Formatters.format_file_size(nil) == "—"
    end
  end
end
