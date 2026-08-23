defmodule MydiaWeb.MediaLive.Show.ScoreBreakdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import MydiaWeb.MediaLive.Show.ScoreBreakdown

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

  # A local wrapper component, because render_component/2 cannot pass a slot
  # ergonomically. Rendering the pair together is also what we actually want to
  # assert: their contract is the link between the two ids.
  defp disclosure(assigns) do
    ~H"""
    <.score_trigger
      id="subtitle-score-badge-0"
      panel_id="subtitle-score-breakdown-0"
      class="badge badge-sm"
    >
      Score 95
    </.score_trigger>
    <.score_panel id="subtitle-score-breakdown-0">
      <.score_row label="Resolution" value="1080p" score={30} max={30} />
    </.score_panel>
    """
  end

  defp disclosure_html, do: render_component(&disclosure/1, %{})

  describe "score_trigger/1 and score_panel/1 disclosure contract" do
    test "the trigger is a real button that points at its panel" do
      doc = LazyHTML.from_fragment(disclosure_html())
      trigger = LazyHTML.query_by_id(doc, "subtitle-score-badge-0")

      assert LazyHTML.attribute(trigger, "type") == ["button"]
      assert LazyHTML.attribute(trigger, "aria-controls") == ["subtitle-score-breakdown-0"]
      assert LazyHTML.attribute(trigger, "aria-expanded") == ["false"]
    end

    test "the trigger keeps the caller's styling" do
      doc = LazyHTML.from_fragment(disclosure_html())
      trigger = LazyHTML.query_by_id(doc, "subtitle-score-badge-0")

      assert LazyHTML.attribute(trigger, "class") == ["badge badge-sm"]
      assert LazyHTML.text(trigger) =~ "Score 95"
    end

    test "the trigger toggles the panel client-side, with no server event" do
      doc = LazyHTML.from_fragment(disclosure_html())
      trigger = LazyHTML.query_by_id(doc, "subtitle-score-badge-0")
      [click] = LazyHTML.attribute(trigger, "phx-click")

      # A JS command list, not an event name. A bare event name would mean a
      # round-trip, which breaks the release dialog's phx-update="stream" list.
      assert click =~ "toggle"
      assert click =~ "subtitle-score-breakdown-0"
      refute click =~ ~s("push")
    end

    test "the panel starts hidden and renders its rows" do
      doc = LazyHTML.from_fragment(disclosure_html())
      panel = LazyHTML.query_by_id(doc, "subtitle-score-breakdown-0")
      [class] = LazyHTML.attribute(panel, "class")

      assert class =~ "hidden"
      assert LazyHTML.text(panel) =~ "Score breakdown"
      assert LazyHTML.text(panel) =~ "Resolution"
      assert LazyHTML.text(panel) =~ "1080p"
    end

    test "the panel is not a positioned dropdown" do
      html = disclosure_html()

      refute html =~ "dropdown"
      refute html =~ "dropdown-content"
    end

    test "the panel title is overridable" do
      html = render_component(&titled_panel/1, %{})

      assert html =~ "Why this ranked here"
      refute html =~ "Score breakdown"
    end
  end

  defp titled_panel(assigns) do
    ~H"""
    <.score_panel id="p" title="Why this ranked here">
      <span>row</span>
    </.score_panel>
    """
  end
end
