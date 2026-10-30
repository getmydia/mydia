defmodule MydiaWeb.AdminIndexersLive.TrackerTermsComponents do
  @moduledoc """
  The Tracker terms section of the Indexers page and its override modal.
  Events live in `MydiaWeb.AdminIndexersLive.TrackerTermsEvents`.
  """
  use MydiaWeb, :html

  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Indexers.TrackerSightings
  alias Mydia.Indexers.TrackerSightings.Row
  alias Mydia.Settings

  @doc "A DOM-safe id fragment for a tracker key."
  @spec dom_key(String.t()) :: String.t()
  def dom_key(key) do
    slug = key |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
    "#{slug}-#{:erlang.phash2(key)}"
  end

  attr :rows, :list, required: true

  def tracker_terms_section(assigns) do
    ~H"""
    <.admin_section
      id="tracker-terms-section"
      title={gettext("Tracker terms")}
      icon="hero-scale"
      count={length(@rows)}
    >
      <:actions>
        <button
          id="new-tracker-rule"
          class="btn btn-xs btn-ghost text-primary"
          phx-click="new_tracker_rule"
        >
          <.icon name="hero-plus" class="w-3 h-3" /> {gettext("Add override")}
        </button>
      </:actions>
      <p class="text-sm text-base-content/70">
        {gettext(
          "Seeding rules each tracker reported in the last %{days} days. An override replaces what the tracker reports; downloads keep the terms in force when they were grabbed.",
          days: TrackerSightings.window_days()
        )}
      </p>
      <.admin_list id="tracker-terms" items={@rows}>
        <:row :let={row}>
          <.tracker_row row={row} />
        </:row>
        <:empty>{gettext("No trackers seen in search results yet.")}</:empty>
      </.admin_list>
    </.admin_section>
    """
  end

  attr :row, Row, required: true

  defp tracker_row(assigns) do
    assigns =
      assigns
      |> assign(:dom_key, dom_key(assigns.row.key))
      |> assign(:runtime?, assigns.row.rule != nil and Settings.runtime_config?(assigns.row.rule))

    ~H"""
    <.admin_row id={"tracker-#{@dom_key}"}>
      <:title>
        {@row.tracker}
        <.env_lock_badge :if={@runtime?} />
      </:title>
      <:descriptor>
        <span id={"tracker-terms-#{@dom_key}"}>{terms_summary(@row.effective)}</span>
        <span :if={limits_summary(@row.rule)} id={"tracker-limits-#{@dom_key}"}>
          · {limits_summary(@row.rule)}
        </span>
      </:descriptor>
      <:details :if={@row.stale?}>
        <span id={"tracker-stale-#{@dom_key}"} class="text-warning text-sm">
          {gettext(
            "This override matched no search result or grab in %{days} days. The tracker may have been renamed in Prowlarr or Jackett.",
            days: TrackerSightings.window_days()
          )}
        </span>
      </:details>
      <:badges>
        <span :if={@row.rule} class="badge badge-sm badge-outline badge-primary">
          {gettext("Override")}
        </span>
        <span :if={@row.stale?} class="badge badge-sm badge-outline badge-warning">
          {gettext("Stale")}
        </span>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"edit-tracker-rule-#{@dom_key}"}
            icon="hero-pencil"
            title={gettext("Edit override")}
            disabled={@runtime?}
            disabled_reason={
              if(@runtime?,
                do: gettext("Cannot edit an override from the config file or environment")
              )
            }
            phx-click="edit_tracker_rule"
            phx-value-tracker={@row.tracker}
          />
          <.row_action
            :if={@row.rule}
            id={"delete-tracker-rule-#{@dom_key}"}
            icon="hero-trash"
            title={gettext("Remove override")}
            destructive
            disabled={@runtime?}
            disabled_reason={
              if(@runtime?,
                do: gettext("Cannot remove an override from the config file or environment")
              )
            }
            phx-click="delete_tracker_rule"
            phx-value-id={@row.rule.id}
            data-confirm={gettext("Remove the override for this tracker?")}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  attr :form, :any, required: true
  attr :mode, :atom, required: true

  def tracker_rule_modal(assigns) do
    ~H"""
    <.admin_modal
      id="tracker-rule-modal"
      icon={if @mode == :new, do: "hero-plus-circle", else: "hero-pencil-square"}
      title={
        if @mode == :new, do: gettext("Add Tracker Override"), else: gettext("Edit Tracker Override")
      }
      subtitle={gettext("Leave a field empty to keep what the tracker reports.")}
      on_close="close_tracker_rule_modal"
    >
      <.form
        for={@form}
        id="tracker-rule-form"
        phx-change="validate_tracker_rule"
        phx-submit="save_tracker_rule"
      >
        <div class="space-y-5">
          <.input
            field={@form[:tracker]}
            type="text"
            label={gettext("Tracker")}
            autocomplete="off"
            required
          />
          <p class="text-xs text-base-content/60 -mt-3">
            {gettext("The tracker name as search results show it. Matching ignores case.")}
          </p>
          <.input
            field={@form[:seed_ratio]}
            type="number"
            step="0.01"
            min="0"
            label={gettext("Minimum ratio")}
          />
          <.input
            field={@form[:seed_time]}
            type="number"
            step="1"
            min="0"
            label={gettext("Minimum seed time (minutes)")}
          />
          <.input
            field={@form[:private]}
            type="select"
            label={gettext("Private tracker")}
            options={[
              {gettext("As reported"), ""},
              {gettext("Yes"), "true"},
              {gettext("No"), "false"}
            ]}
          />
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:grab_limit]}
              type="number"
              step="1"
              min="0"
              label={gettext("Grabs per day")}
            />
            <.input
              field={@form[:query_limit]}
              type="number"
              step="1"
              min="0"
              label={gettext("Searches per day")}
            />
          </div>
          <p class="text-xs text-base-content/60 -mt-3">
            {gettext(
              "Optional caps over a rolling 24 hours. At a cap, automatic search skips this tracker and manual search says why. Searches count only for an indexer named after the tracker; Prowlarr enforces its own limits for the trackers behind it."
            )}
          </p>
        </div>

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_tracker_rule_modal">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary gap-2">
            <.icon name="hero-check" class="w-4 h-4" />
            {gettext("Save Override")}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  @doc "One line describing effective terms, e.g. \"Private · Ratio 1.0 · Seed 3d\"."
  @spec terms_summary(TrackerTerms.t() | nil) :: String.t()
  def terms_summary(nil), do: gettext("No seeding rules reported")

  def terms_summary(%TrackerTerms{} = terms) do
    [
      privacy(terms.private?),
      terms.minimum_ratio && gettext("Ratio %{ratio}", ratio: format_ratio(terms.minimum_ratio)),
      terms.minimum_seed_time &&
        gettext("Seed %{time}", time: format_seed_time(terms.minimum_seed_time))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> gettext("No seeding rules reported")
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc "The rule's daily caps, e.g. \"5 grabs/day · 50 searches/day\", or nil."
  @spec limits_summary(map() | nil) :: String.t() | nil
  def limits_summary(nil), do: nil

  def limits_summary(rule) do
    [
      rule.grab_limit && gettext("%{count} grabs/day", count: rule.grab_limit),
      rule.query_limit && gettext("%{count} searches/day", count: rule.query_limit)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp privacy(true), do: gettext("Private")
  defp privacy(false), do: gettext("Public")
  defp privacy(nil), do: nil

  defp format_ratio(ratio), do: :erlang.float_to_binary(ratio * 1.0, [:short])

  defp format_seed_time(seconds) when seconds < 60,
    do: gettext("%{count}s", count: seconds)

  defp format_seed_time(seconds) when rem(seconds, 86_400) == 0 and seconds > 0,
    do: gettext("%{count}d", count: div(seconds, 86_400))

  defp format_seed_time(seconds) when rem(seconds, 3600) == 0 and seconds > 0,
    do: gettext("%{count}h", count: div(seconds, 3600))

  defp format_seed_time(seconds), do: gettext("%{count}m", count: div(seconds, 60))
end
