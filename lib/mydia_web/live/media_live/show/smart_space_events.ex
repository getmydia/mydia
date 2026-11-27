defmodule MydiaWeb.MediaLive.Show.SmartSpaceEvents do
  @moduledoc """
  Smart Space on the TV show page: loads the show's effective rule, the
  cleanups due within 30 days and its keeps, and handles the override modal and
  the Keep toggles.

  Data loads once on mount and again after each Smart Space event, not on every
  `load_media_item/2`. Movies get nothing: `smart_space_rule` and the rest stay
  empty and the components render no controls.

  Events arrive as `smart_space_<action>`, routed here by one clause in the
  LiveView.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.SmartSpace
  alias Mydia.SmartSpace.{Evaluator, Loader, Rules}
  alias MydiaWeb.Live.Authorization

  @within_days 30

  @doc "Assigns the Smart Space state for the page. Call after `:media_item` is assigned."
  def assign_smart_space(socket, %{type: "tv_show", id: id}) do
    inputs = Loader.load(media_item_id: id)
    show = Enum.find(inputs.shows, &(&1.media_item_id == id))

    socket
    |> assign(:smart_space?, true)
    |> assign(:smart_space_rule, show && Evaluator.effective_rule(inputs, show))
    |> assign(:smart_space_override, Rules.get_override(id))
    |> assign(:smart_space_due, due_map(id))
    |> assign(:smart_space_keeps, keep_set(id))
    |> assign(:show_smart_space_modal, false)
  end

  def assign_smart_space(socket, _media_item) do
    socket
    |> assign(:smart_space?, false)
    |> assign(:smart_space_rule, nil)
    |> assign(:smart_space_override, nil)
    |> assign(:smart_space_due, %{})
    |> assign(:smart_space_keeps, MapSet.new())
    |> assign(:show_smart_space_modal, false)
  end

  @doc "Dispatches a `smart_space_<action>` event."
  def handle("open", _params, socket) do
    with :ok <- authorize_edit(socket) do
      override = socket.assigns.smart_space_override

      form =
        to_form(
          %{
            "mode" => (override && override.mode) || "inherit",
            "unit" => (override && override.unit) || "season",
            "grace_days" => to_string((override && override.grace_days) || 7)
          },
          as: :smart_space
        )

      {:noreply,
       socket |> assign(:smart_space_form, form) |> assign(:show_smart_space_modal, true)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle("close", _params, socket),
    do: {:noreply, assign(socket, :show_smart_space_modal, false)}

  def handle("validate", %{"smart_space" => params}, socket),
    do: {:noreply, assign(socket, :smart_space_form, to_form(params, as: :smart_space))}

  def handle("save", %{"smart_space" => params}, socket) do
    with :ok <- authorize_edit(socket) do
      case Rules.put_override(socket.assigns.media_item.id, override_attrs(params)) do
        {:ok, _override} ->
          {:noreply,
           socket
           |> reload(socket.assigns.media_item)
           |> put_flash(:info, gettext("Smart Space setting saved"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save the Smart Space setting"))}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle("keep", params, socket) do
    with :ok <- Authorization.authorize_delete_media(socket),
         {:ok, target} <- keep_target(params, socket.assigns.media_item.id) do
      if MapSet.member?(socket.assigns.smart_space_keeps, keep_key(target)) do
        Rules.unkeep(target)
      else
        Rules.keep(target, socket.assigns.current_user)
      end

      {:noreply, reload(socket, socket.assigns.media_item)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      :error -> {:noreply, socket}
    end
  end

  defp reload(socket, media_item), do: assign_smart_space(socket, media_item)

  defp authorize_edit(socket), do: Authorization.authorize_update_media(socket)

  # "inherit" deletes the row; "off" needs no unit or grace.
  defp override_attrs(%{"mode" => "custom"} = params) do
    %{mode: "custom", unit: params["unit"], grace_days: parse_int(params["grace_days"])}
  end

  defp override_attrs(params), do: %{mode: params["mode"]}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp keep_target(%{"episode-id" => episode_id}, media_item_id) when episode_id != "",
    do: {:ok, {:episode, media_item_id, episode_id}}

  defp keep_target(%{"season-number" => season}, media_item_id) do
    case parse_int(season) do
      nil -> :error
      number -> {:ok, {:season, media_item_id, number}}
    end
  end

  defp keep_target(_params, _media_item_id), do: :error

  defp keep_key({:season, _id, number}), do: {:season, number}
  defp keep_key({:episode, _id, episode_id}), do: {:episode, episode_id}

  # `{season, nil}` for a season cleanup, `{season, episode_id}` per episode of
  # an episode cleanup.
  defp due_map(media_item_id) do
    [media_item_id: media_item_id, within_days: @within_days]
    |> SmartSpace.upcoming()
    |> Enum.flat_map(fn
      %{unit: :season} = cleanup ->
        [{{cleanup.season_number, nil}, cleanup.eligible_at}]

      %{unit: :episode} = cleanup ->
        for id <- cleanup.episode_ids, do: {{cleanup.season_number, id}, cleanup.eligible_at}
    end)
    |> Map.new()
  end

  defp keep_set(media_item_id) do
    [media_item_id: media_item_id]
    |> Rules.list_keeps()
    |> MapSet.new(fn
      %{episode_id: id} when not is_nil(id) -> {:episode, id}
      %{season_number: n} when not is_nil(n) -> {:season, n}
      _show_keep -> :show
    end)
  end
end
