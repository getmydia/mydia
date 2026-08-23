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

  alias Phoenix.LiveView.JS

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

  @doc """
  Trigger button for a score breakdown panel.

  An inline disclosure rather than a daisyUI `dropdown`, because a hover-driven
  panel is not a dependable touch affordance. daisyUI hides a `dropdown-hover`
  panel whenever its trigger has `:focus` without `:focus-visible`, so the only
  thing keeping it open after a tap is the sticky `:hover` the tap happens to
  leave behind, which no touch platform guarantees and which any scroll can
  clear. Focus, the one state a tap reliably leaves, is excluded by that rule.

  A hidden sibling opens on an explicit tap and stays open until tapped again.
  It also spans the row rather than a fixed `w-64`, and because it is in flow it
  grows its scrolling ancestor's scroll extent instead of overhanging it.

  The toggle is a client-side `JS` command, not a server event, so it costs no
  round-trip and does not fight the release dialog's `phx-update="stream"` list.
  """
  attr :id, :string, required: true
  attr :panel_id, :string, required: true
  attr :class, :any, default: nil
  attr :style, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def score_trigger(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class={@class}
      style={@style}
      aria-expanded="false"
      aria-controls={@panel_id}
      phx-click={
        JS.toggle(to: "##{@panel_id}")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{@id}")
      }
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  The panel a `score_trigger/1` opens, hidden until it is toggled.

  Carries no width of its own. It is placed by its caller inside the row's
  content column, so it spans that column instead of floating as a fixed-width
  card anchored to a badge.
  """
  attr :id, :string, required: true
  attr :title, :string, default: "Score breakdown"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def score_panel(assigns) do
    ~H"""
    <div id={@id} role="region" class={["hidden mt-2 rounded-box bg-base-200 p-3", @class]}>
      <h4 class="text-sm font-semibold mb-2">{@title}</h4>
      <div class="space-y-1.5 text-xs">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
