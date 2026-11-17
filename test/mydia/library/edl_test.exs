defmodule Mydia.Library.EdlTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Edl

  describe "parse/1" do
    test "reads Comskip output: tabs, CRLF, a trailing blank line" do
      assert Edl.parse("0.00\t25.03\t0\r\n612.48\t735.10\t3\r\n\r\n") ==
               [{0, 25_030}, {612_480, 735_100}]
    end

    test "reads hh:mm:ss and mm:ss timestamps" do
      assert Edl.parse("00:10:12.500 00:12:00 3\n") == [{612_500, 720_000}]
      assert Edl.parse("10:12.5 12:00 0") == [{612_500, 720_000}]
    end

    test "treats a line with no action as a cut" do
      assert Edl.parse("5 10") == [{5_000, 10_000}]
    end

    test "drops mute, scene marker and unknown actions" do
      assert Edl.parse("5 10 1\n20 30 2\n40 50 7") == []
    end

    test "drops frame-number lines" do
      assert Edl.parse("#100 #200 0") == []
    end

    test "drops lines it cannot parse" do
      assert Edl.parse("hello\n5 x 0\n") == []
      assert Edl.parse("5 10 0 extra") == []
      assert Edl.parse("") == []
    end

    test "drops reversed and zero-length ranges" do
      assert Edl.parse("10 5 0\n7 7 0") == []
    end

    test "sorts and merges overlapping and touching ranges" do
      assert Edl.parse("50 60 0\n10 20 0\n15 30 3\n30 40 0") ==
               [{10_000, 40_000}, {50_000, 60_000}]
    end

    test "drops ranges past the integer column's limit" do
      # 2,147,484 seconds is just over 2^31 - 1 milliseconds, which would
      # overflow the PostgreSQL `integer` column and abort the insert.
      assert Edl.parse("0 2147484 0\n5 10 0") == [{5_000, 10_000}]
    end

    test "drops a time so large the arithmetic would overflow" do
      assert Edl.parse("0 1.0e308 0\n5 10 0") == [{5_000, 10_000}]
      assert Edl.parse("1.0e308:00:00 1.0e308:00:01 0\n5 10 0") == [{5_000, 10_000}]
    end

    test "drops negative times" do
      assert Edl.parse("-5 10 0") == []
    end
  end
end
