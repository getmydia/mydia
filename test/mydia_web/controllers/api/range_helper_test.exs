defmodule MydiaWeb.Api.RangeHelperTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.Api.RangeHelper

  describe "parse_range_header/2" do
    test "explicit range" do
      assert RangeHelper.parse_range_header("bytes=0-499", 1000) == {:ok, 0, 499}
    end

    test "open-ended range" do
      assert RangeHelper.parse_range_header("bytes=100-", 1000) == {:ok, 100, 999}
    end

    test "clamps an end past EOF" do
      assert RangeHelper.parse_range_header("bytes=0-65535", 10_240) == {:ok, 0, 10_239}
    end

    test "suffix range returns the last N bytes" do
      assert RangeHelper.parse_range_header("bytes=-500", 1000) == {:ok, 500, 999}
    end

    test "suffix larger than the file returns the whole file" do
      assert RangeHelper.parse_range_header("bytes=-99999", 1000) == {:ok, 0, 999}
    end

    test "zero-length suffix is unsatisfiable" do
      assert RangeHelper.parse_range_header("bytes=-0", 1000) == :error
    end

    test "start beyond EOF is unsatisfiable" do
      assert RangeHelper.parse_range_header("bytes=1000-", 1000) == :error
      assert RangeHelper.parse_range_header("bytes=5000-6000", 1000) == :error
    end

    test "start after end is unsatisfiable" do
      assert RangeHelper.parse_range_header("bytes=500-100", 1000) == :error
    end

    test "empty file is unsatisfiable for any range" do
      assert RangeHelper.parse_range_header("bytes=0-", 0) == :error
      assert RangeHelper.parse_range_header("bytes=0-10", 0) == :error
      assert RangeHelper.parse_range_header("bytes=-5", 0) == :error
    end

    test "garbage is rejected" do
      assert RangeHelper.parse_range_header("bytes=invalid", 1000) == :error
      assert RangeHelper.parse_range_header("bytes=-", 1000) == :error
      assert RangeHelper.parse_range_header("bytes=a-b", 1000) == :error
      assert RangeHelper.parse_range_header("items=0-5", 1000) == :error
      assert RangeHelper.parse_range_header("bytes=0-5,10-20", 1000) == :error
    end

    test "nil and empty are rejected" do
      assert RangeHelper.parse_range_header(nil, 1000) == :error
      assert RangeHelper.parse_range_header("", 1000) == :error
    end
  end
end
