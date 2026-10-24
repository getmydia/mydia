defmodule Mydia.RatchetTest do
  use ExUnit.Case, async: true

  alias Mydia.Ratchet

  describe "count_lines/1" do
    test "counts newline characters like wc -l" do
      assert Ratchet.count_lines("") == 0
      assert Ratchet.count_lines("a\n") == 1
      assert Ratchet.count_lines("a\nb\n") == 2
      assert Ratchet.count_lines("a\nb") == 1
    end
  end

  describe "size_regressions/3" do
    test "ignores files at or under the limit, new or grown" do
      assert Ratchet.size_regressions(%{"lib/a.ex" => 10}, %{}, 10) == []
      assert Ratchet.size_regressions(%{"lib/a.ex" => 10}, %{"lib/a.ex" => 3}, 10) == []
    end

    test "flags a new file over the limit" do
      assert Ratchet.size_regressions(%{"lib/a.ex" => 11}, %{}, 10) == [{:new, "lib/a.ex", 11}]
    end

    test "flags an oversized file that grew" do
      assert Ratchet.size_regressions(%{"lib/a.ex" => 12}, %{"lib/a.ex" => 11}, 10) ==
               [{:grew, "lib/a.ex", 11, 12}]
    end

    test "allows an oversized file that stayed the same or shrank" do
      assert Ratchet.size_regressions(%{"lib/a.ex" => 11}, %{"lib/a.ex" => 11}, 10) == []
      assert Ratchet.size_regressions(%{"lib/a.ex" => 11}, %{"lib/a.ex" => 20}, 10) == []
    end

    test "flags a file that crossed the limit from below" do
      assert Ratchet.size_regressions(%{"lib/a.ex" => 11}, %{"lib/a.ex" => 9}, 10) ==
               [{:grew, "lib/a.ex", 9, 11}]
    end

    test "sorts regressions by path" do
      current = %{"lib/b.ex" => 11, "lib/a.ex" => 11}

      assert [{:new, "lib/a.ex", 11}, {:new, "lib/b.ex", 11}] =
               Ratchet.size_regressions(current, %{}, 10)
    end
  end

  defp issue(check, scope, message, filename \\ "lib/x.ex") do
    %{
      "check" => "Credo.Check.Refactor." <> check,
      "scope" => scope,
      "message" => message,
      "filename" => filename,
      "line_no" => 1
    }
  end

  @cc15 "Function is too complex (cyclomatic complexity is 15, max is 9)."
  @cc16 "Function is too complex (cyclomatic complexity is 16, max is 9)."
  @nest3 "Function body is nested too deep (max depth is 2, was 3)."

  describe "issue_key/1" do
    test "uses the check and the last scope segment, not the measured value" do
      assert Ratchet.issue_key(issue("Nesting", "Mydia.Media.Items.rescan", @nest3)) ==
               {"Credo.Check.Refactor.Nesting", "rescan"}

      assert Ratchet.issue_key(issue("CyclomaticComplexity", "M.f", @cc15)) ==
               Ratchet.issue_key(issue("CyclomaticComplexity", "M.f", @cc16))
    end

    test "tolerates a nil scope" do
      assert {"Credo.Check.Refactor.Nesting", ""} =
               Ratchet.issue_key(issue("Nesting", nil, @nest3))
    end
  end

  describe "issue_value/1" do
    test "reads the complexity from a cyclomatic complexity message" do
      assert Ratchet.issue_value(issue("CyclomaticComplexity", "M.f", @cc15)) == 15
    end

    test "reads the depth from a nesting message" do
      assert Ratchet.issue_value(issue("Nesting", "M.f", @nest3)) == 3
    end

    test "raises, naming the issue, when the message has no parseable value" do
      error =
        assert_raise ArgumentError, fn ->
          Ratchet.issue_value(issue("Nesting", "Mydia.Media.rescan", "Too nested."))
        end

      assert error.message =~ "Mydia.Media.rescan"
      assert error.message =~ "Too nested."
    end
  end

  describe "complexity_regressions/2" do
    test "a function moved to another module and file is not a regression" do
      base = [issue("CyclomaticComplexity", "Mydia.Media.rescan", @cc15, "lib/mydia/media.ex")]

      head = [
        issue(
          "CyclomaticComplexity",
          "Mydia.Media.Rescan.rescan",
          @cc15,
          "lib/mydia/media/rescan.ex"
        )
      ]

      assert Ratchet.complexity_regressions(base, head) == []
    end

    test "a function that got more complex is a regression" do
      base = [issue("CyclomaticComplexity", "M.f", @cc15)]
      head = [issue("CyclomaticComplexity", "M.f", @cc16)]
      assert [%{"message" => @cc16}] = Ratchet.complexity_regressions(base, head)
    end

    test "a new nested function is a regression" do
      assert [%{"scope" => "M.g"}] =
               Ratchet.complexity_regressions([], [issue("Nesting", "M.g", @nest3)])
    end

    test "counts duplicate keys as a multiset" do
      base = [issue("Nesting", "M.f", @nest3)]
      head = [issue("Nesting", "M.f", @nest3), issue("Nesting", "M.f", @nest3)]
      assert [_one] = Ratchet.complexity_regressions(base, head)
    end

    test "a function that got less complex is not a regression" do
      base = [issue("CyclomaticComplexity", "M.f", @cc16)]
      head = [issue("CyclomaticComplexity", "M.f", @cc15)]
      assert Ratchet.complexity_regressions(base, head) == []
    end

    test "a function that got less nested is not a regression" do
      deeper = "Function body is nested too deep (max depth is 2, was 4)."

      assert Ratchet.complexity_regressions([issue("Nesting", "M.f", deeper)], [
               issue("Nesting", "M.f", @nest3)
             ]) == []
    end

    test "an unparseable head message is not silently accepted" do
      base = [issue("CyclomaticComplexity", "M.f", @cc15)]
      head = [issue("CyclomaticComplexity", "M.f", "Too complex.")]
      assert_raise ArgumentError, fn -> Ratchet.complexity_regressions(base, head) end
    end

    test "mixed duplicates flag only the one that rose" do
      cc12 = "Function is too complex (cyclomatic complexity is 12, max is 9)."
      cc13 = "Function is too complex (cyclomatic complexity is 13, max is 9)."
      cyclo = &issue("CyclomaticComplexity", "M.f", &1)

      assert [%{"message" => ^cc13}] =
               Ratchet.complexity_regressions([cyclo.(@cc16), cyclo.(cc12)], [
                 cyclo.(@cc15),
                 cyclo.(cc13)
               ])
    end

    test "a differing count flags the extra issue, and a rise among the paired ones" do
      cyclo = &issue("CyclomaticComplexity", "M.f", &1)

      # one fewer in head, remaining one lower: fine
      assert Ratchet.complexity_regressions([cyclo.(@cc16), cyclo.(@cc15)], [cyclo.(@cc15)]) ==
               []

      # one extra in head: the lowest-valued head issue has no partner
      assert [%{"message" => @cc15}] =
               Ratchet.complexity_regressions([cyclo.(@cc16)], [cyclo.(@cc16), cyclo.(@cc15)])
    end

    test "duplicates pair largest to largest" do
      base = [
        issue("CyclomaticComplexity", "M.f", @cc16),
        issue("CyclomaticComplexity", "M.f", @cc15)
      ]

      same = [
        issue("CyclomaticComplexity", "M.f", @cc15),
        issue("CyclomaticComplexity", "M.f", @cc15)
      ]

      worse = [
        issue("CyclomaticComplexity", "M.f", @cc16),
        issue("CyclomaticComplexity", "M.f", @cc16)
      ]

      assert Ratchet.complexity_regressions(base, same) == []
      assert [%{"message" => @cc16}] = Ratchet.complexity_regressions(base, worse)
    end

    test "fixed issues are never regressions" do
      assert Ratchet.complexity_regressions([issue("Nesting", "M.f", @nest3)], []) == []
    end
  end

  describe "parse_credo_json/1" do
    test "skips banner lines before the JSON object" do
      output =
        "Compiling 1 file\n{\n  \"issues\": [{\"check\": \"C\", \"scope\": \"M.f\", \"message\": \"m\"}]\n}\n"

      assert [%{"check" => "C"}] = Ratchet.parse_credo_json(output)
    end

    test "parses compact single-line JSON after a banner line" do
      output = "banner\n{\"issues\": [{\"check\": \"C\"}]}\n"

      assert [%{"check" => "C"}] = Ratchet.parse_credo_json(output)
    end

    test "raises when no JSON object is present" do
      assert_raise ArgumentError, fn -> Ratchet.parse_credo_json("boom\n") end
    end
  end

  describe "text_regressions/2" do
    test "flags a new file with literal text, ignores a new clean file" do
      assert Ratchet.text_regressions(%{"a.ex" => 2, "b.ex" => 0}, %{}) == [{:new, "a.ex", 2}]
    end

    test "flags growth, allows equal or fewer" do
      assert Ratchet.text_regressions(%{"a.ex" => 3}, %{"a.ex" => 2}) == [{:grew, "a.ex", 2, 3}]
      assert Ratchet.text_regressions(%{"a.ex" => 2}, %{"a.ex" => 2}) == []
      assert Ratchet.text_regressions(%{"a.ex" => 1}, %{"a.ex" => 2}) == []
    end

    test "formats both kinds" do
      assert Ratchet.format_text_regression({:new, "a.ex", 2}) =~ "a.ex"
      assert Ratchet.format_text_regression({:grew, "a.ex", 2, 3}) =~ "2 -> 3"
    end
  end

  describe "formatting" do
    test "names the file, the counts and the fix" do
      assert Ratchet.format_size_regression({:new, "lib/a.ex", 900}) =~ "lib/a.ex"
      assert Ratchet.format_size_regression({:grew, "lib/a.ex", 850, 900}) =~ "850"
      assert Ratchet.format_issue(issue("Nesting", "M.f", @nest3)) =~ "M.f"
    end
  end
end
