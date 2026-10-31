defmodule MydiaWeb.MediaLive.Show.TrackerLimitNote do
  @moduledoc """
  Why a manual search row's tracker is at its daily grab cap
  (`Mydia.Indexers.TrackerLimits`), e.g. "daily grab limit reached (5/5)".

  Background searches skip such a tracker; the manual search dialog keeps the
  row, says why, and still lets the user grab it. The caps are loaded into
  the `:grab_caps` assign with the dialog's other per-search lookups, and
  `put_limit_reason/2` writes the reason onto each row as it is streamed.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Indexers.TrackerLimits

  require Logger

  @doc "Sets `result.limit_reason` from `caps` (`TrackerLimits.grab_caps/1`)."
  @spec put_limit_reason(map(), map()) :: map()
  def put_limit_reason(result, caps) do
    reason =
      case TrackerLimits.cap_for(result, caps) do
        {count, limit} ->
          gettext("daily grab limit reached (%{count}/%{limit})", count: count, limit: limit)

        nil ->
          nil
      end

    Map.put(result, :limit_reason, reason)
  end

  @doc "The grab caps for the dialog, or none if the lookup fails."
  @spec load_caps() :: map()
  def load_caps do
    TrackerLimits.grab_caps()
  rescue
    error ->
      Logger.warning("Tracker grab cap lookup failed: #{Exception.message(error)}")
      %{}
  end

  attr :id, :string, required: true
  attr :reason, :string, default: nil

  def limit_note(assigns) do
    ~H"""
    <div :if={@reason} id={@id} class="text-xs text-warning mt-1 flex items-center gap-1">
      <.icon name="hero-clock" class="w-3.5 h-3.5 shrink-0" /> {@reason}
    </div>
    """
  end
end
