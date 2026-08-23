defmodule MydiaWeb.MediaLive.Show.ScoreBreakdown do
  @moduledoc """
  Score breakdown rows shared by the release search and subtitle search modals.

  Both modals explain a ranking the same way, so the rows live here rather than
  in either one. The two scales differ: the release ranker works in percentages
  of a 100-point total, and the subtitle scorer works in absolute points out of
  a per-factor maximum. `score_row/1` covers both through `:weight`, which is
  omitted when there is no percentage to show, and `:max`, which colours by
  ratio rather than against a fixed scale.
  """
  use Phoenix.Component

  @doc """
  One factor of a score breakdown.

  `:weight` renders a percentage column and is omitted when the caller's
  factors are absolute. `:max` is the highest this factor can score, used to
  colour the value. `:zero_is_absent` means a score of 0 for this factor
  indicates the signal was unavailable rather than bad, so it renders neutral
  instead of `text-error`.
  """
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :score, :any, default: nil
  attr :weight, :integer, default: nil
  attr :max, :integer, default: 100
  attr :zero_is_absent, :boolean, default: false

  def score_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2">
      <div class="flex items-center gap-2 flex-1 min-w-0">
        <span class="text-base-content/70 whitespace-nowrap">{@label}:</span>
        <span class="font-medium truncate">
          {display_value(@value)}
        </span>
      </div>
      <div class="flex items-center gap-1.5 flex-shrink-0">
        <span class={[
          "font-mono font-semibold w-8 text-right",
          score_color(@score, @max, @zero_is_absent)
        ]}>
          {format_score(@score)}
        </span>
        <span :if={@weight} class="text-base-content/50 text-[10px] w-8">
          ({@weight}%)
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Penalty breakdown row, rendered only for a non-zero penalty.

  A `-` prefix and a warning colour keep a penalty from reading as a weak
  positive score. No weight column, which is meaningless for a penalty.
  """
  attr :label, :string, required: true
  attr :score, :float, default: 0.0

  def penalty_row(assigns) do
    ~H"""
    <div :if={@score < 0.0} class="flex items-center justify-between gap-2">
      <div class="flex items-center gap-2 flex-1 min-w-0">
        <span class="text-base-content/70 whitespace-nowrap">{@label}:</span>
      </div>
      <div class="flex items-center gap-1.5 flex-shrink-0">
        <span class="font-mono font-semibold w-10 text-right text-warning">
          −{abs(trunc(@score))}
        </span>
      </div>
    </div>
    """
  end

  @doc "Renders a factor's detected value, or a dash when it has none."
  def display_value(nil), do: "-"
  def display_value(value), do: value

  @doc "Renders a factor's score, truncating a float."
  def format_score(nil), do: "-"
  def format_score(score) when is_float(score), do: trunc(score)
  def format_score(score), do: score

  @doc """
  Colours a factor by how much of its maximum it earned.

  A ratio rather than a fixed scale, so a factor worth 20 points reads as full
  marks at 20 instead of as a failure against a 100-point yardstick. With the
  default max of 100 this reproduces the release ranker's original 80 and 50
  thresholds exactly.

  `zero_is_absent` controls how an exact zero renders. When `true`, it renders
  in the same neutral colour as a nil score rather than `text-error`: on a
  relay result "Hash match" is a permanent zero because SubDL has no hash
  search, and a naming gap means the parser had nothing to compare, so
  painting those zeros red reads as "several things are wrong" when the
  honest story is "these signals are unavailable." When `false` (the
  default), a zero is scored normally against `max` like any other value, so
  a genuinely bad result, such as a torrent with zero known seeders, still
  reads as `text-error`.
  """
  def score_color(score, max, zero_is_absent \\ false)
  def score_color(nil, _max, _zero_is_absent), do: "text-base-content/50"

  def score_color(_score, max, _zero_is_absent) when not is_number(max) or max <= 0,
    do: "text-base-content/50"

  def score_color(score, _max, true) when score == 0, do: "text-base-content/50"

  def score_color(score, max, _zero_is_absent) do
    cond do
      score / max >= 0.8 -> "text-success"
      score / max >= 0.5 -> "text-warning"
      true -> "text-error"
    end
  end
end
