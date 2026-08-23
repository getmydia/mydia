defmodule MydiaWeb.MediaLive.Show.ScoreBreakdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.MediaLive.Show.ScoreBreakdown

  defp row(assigns) do
    render_component(&ScoreBreakdown.score_row/1, assigns)
  end

  # The score value's own span, not the surrounding row (which always
  # carries a `text-base-content/*` class on the label and, when `:weight`
  # is set, on the percentage suffix too).
  defp score_span_class(html) do
    [[_, class]] = Regex.scan(~r/font-mono font-semibold w-8 text-right ([\w\/-]+)/, html)
    class
  end

  describe "score_row/1 zero handling" do
    test "a zero score with zero_is_absent renders neutral, not text-error" do
      html = row(label: "Hash match", score: 0, max: 10, zero_is_absent: true)

      assert score_span_class(html) == "text-base-content/50"
    end

    test "a zero score without zero_is_absent renders text-error" do
      html = row(label: "Seeders", score: 0.0, max: 10, weight: 30)

      assert score_span_class(html) == "text-error"
    end

    test "a nil score renders neutral with zero_is_absent true" do
      html = row(label: "Hash match", score: nil, max: 10, zero_is_absent: true)

      assert score_span_class(html) == "text-base-content/50"
    end

    test "a nil score renders neutral with zero_is_absent false (default)" do
      html = row(label: "Seeders", score: nil, max: 10)

      assert score_span_class(html) == "text-base-content/50"
    end
  end

  describe "score_row/1 non-zero scores are unaffected by zero_is_absent" do
    test "a high score reads text-success regardless of the flag" do
      with_flag = row(label: "Resolution", score: 90, max: 100, zero_is_absent: true)
      without_flag = row(label: "Resolution", score: 90, max: 100)

      assert score_span_class(with_flag) == "text-success"
      assert score_span_class(without_flag) == "text-success"
    end

    test "a mid score reads text-warning regardless of the flag" do
      with_flag = row(label: "Resolution", score: 60, max: 100, zero_is_absent: true)
      without_flag = row(label: "Resolution", score: 60, max: 100)

      assert score_span_class(with_flag) == "text-warning"
      assert score_span_class(without_flag) == "text-warning"
    end

    test "a low but non-zero score reads text-error regardless of the flag" do
      with_flag = row(label: "Resolution", score: 5, max: 100, zero_is_absent: true)
      without_flag = row(label: "Resolution", score: 5, max: 100)

      assert score_span_class(with_flag) == "text-error"
      assert score_span_class(without_flag) == "text-error"
    end
  end

  describe "score_color/3 invalid max short-circuits safely" do
    test "a zero max renders neutral instead of dividing by zero" do
      assert ScoreBreakdown.score_color(5, 0) == "text-base-content/50"
    end

    test "a negative max renders neutral instead of dividing" do
      assert ScoreBreakdown.score_color(5, -10) == "text-base-content/50"
    end

    test "a non-numeric max renders neutral instead of raising" do
      assert ScoreBreakdown.score_color(5, nil) == "text-base-content/50"
      assert ScoreBreakdown.score_color(5, "100") == "text-base-content/50"
    end
  end

  describe "score_color/3 flag defaults" do
    test "defaults to false, treating an exact zero as a bad score" do
      assert ScoreBreakdown.score_color(0, 10) == "text-error"
    end

    test "zero_is_absent true treats an exact zero as neutral" do
      assert ScoreBreakdown.score_color(0, 10, true) == "text-base-content/50"
    end

    test "a nil score is always neutral regardless of the flag" do
      assert ScoreBreakdown.score_color(nil, 10) == "text-base-content/50"
      assert ScoreBreakdown.score_color(nil, 10, true) == "text-base-content/50"
    end
  end
end
