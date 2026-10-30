defmodule MydiaWeb.AdminIndexersLive.TrackerTermsEvents do
  @moduledoc """
  The Tracker terms section of the Indexers page as LiveView hooks, so
  `AdminIndexersLive.Index` gains only an `attach/1` call (the same pattern as
  `SearchStatsEvents`).

  Rows come from `Mydia.Indexers.TrackerSightings.list_trackers/1`. Edit on a
  tracker without a database rule opens the form to create one; a YAML or env
  rule is read-only here.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 1]
  import Phoenix.LiveView

  alias Mydia.Indexers.TrackerRules
  alias Mydia.Indexers.TrackerSightings
  alias Mydia.Settings
  alias Mydia.Settings.TrackerRuleConfig

  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(show_tracker_rule_modal: false, tracker_rule_mode: :new, editing_tracker_rule: nil)
    |> refresh()
    |> attach_hook(:tracker_terms_events, :handle_event, &handle_event/3)
  end

  @doc "Reloads the tracker rows."
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket), do: assign(socket, :tracker_terms, TrackerSightings.list_trackers())

  defp handle_event("new_tracker_rule", _params, socket),
    do: {:halt, open_modal(socket, :new, %TrackerRuleConfig{})}

  defp handle_event("edit_tracker_rule", %{"tracker" => tracker}, socket) do
    case TrackerRules.rule_for(tracker) do
      nil ->
        {:halt, open_modal(socket, :new, %TrackerRuleConfig{tracker: tracker})}

      rule ->
        if Settings.runtime_config?(rule),
          do: {:halt, put_flash(socket, :error, env_readonly_message())},
          else: {:halt, open_modal(socket, :edit, rule)}
    end
  end

  defp handle_event("validate_tracker_rule", %{"tracker_rule_config" => params}, socket) do
    changeset =
      socket
      |> base_rule()
      |> TrackerRuleConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:halt, assign(socket, :tracker_rule_form, to_form(changeset))}
  end

  defp handle_event("save_tracker_rule", %{"tracker_rule_config" => params}, socket) do
    result =
      case socket.assigns.tracker_rule_mode do
        :new -> Settings.create_tracker_rule_config(params)
        :edit -> Settings.update_tracker_rule_config(socket.assigns.editing_tracker_rule, params)
      end

    case result do
      {:ok, _rule} ->
        {:halt,
         socket
         |> assign(:show_tracker_rule_modal, false)
         |> put_flash(:info, gettext("Tracker override saved"))
         |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:halt, assign(socket, :tracker_rule_form, to_form(changeset))}
    end
  end

  defp handle_event("delete_tracker_rule", %{"id" => id}, socket) do
    rule = Settings.get_tracker_rule_config!(id)

    cond do
      Settings.runtime_config?(rule) ->
        {:halt, put_flash(socket, :error, env_readonly_message())}

      match?({:ok, _}, Settings.delete_tracker_rule_config(rule)) ->
        {:halt, socket |> put_flash(:info, gettext("Tracker override removed")) |> refresh()}

      true ->
        {:halt, put_flash(socket, :error, gettext("Failed to remove the tracker override"))}
    end
  end

  defp handle_event("close_tracker_rule_modal", _params, socket),
    do: {:halt, assign(socket, :show_tracker_rule_modal, false)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp open_modal(socket, mode, rule) do
    socket
    |> assign(show_tracker_rule_modal: true, tracker_rule_mode: mode)
    |> assign(:editing_tracker_rule, if(mode == :edit, do: rule))
    |> assign(:tracker_rule_form, to_form(TrackerRuleConfig.changeset(rule, %{})))
  end

  defp base_rule(socket) do
    case socket.assigns.tracker_rule_mode do
      :edit -> socket.assigns.editing_tracker_rule
      :new -> %TrackerRuleConfig{}
    end
  end

  defp env_readonly_message do
    gettext(
      "This override is configured in the config file or environment and is read-only here."
    )
  end
end
