defmodule MydiaWeb.AdminSmartSpaceLive.Index do
  @moduledoc """
  Lists what Smart Space will move to the trash in the next 30 days, and the
  keeps that exempt shows, seasons and episodes from it.

  Both lists are streams that are reset after every action: a keep changes what
  is upcoming (the evaluator skips kept units), so the list is recomputed
  rather than patched.
  """
  use MydiaWeb, :live_view

  import Ecto.Query

  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Media.Episode
  alias Mydia.Repo
  alias Mydia.SmartSpace
  alias Mydia.SmartSpace.Rules

  @within_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Administration - Smart Space"))
     |> assign(:tab, :upcoming)
     |> assign(:bytes_due, 0)
     |> assign(:last_run_at, nil)
     |> assign(:enabled?, false)
     |> assign(:upcoming_count, 0)
     |> assign(:keeps_count, 0)
     |> stream_configure(:upcoming, dom_id: & &1.id)
     |> stream_configure(:keeps, dom_id: &"smart-space-keep-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] == "kept", do: :kept, else: :upcoming
    # Reload on every tab change: a stream filled while its container was not
    # rendered (the other tab) would be empty when the tab opens.
    {:noreply, socket |> assign(:tab, tab) |> load()}
  end

  @impl true
  def handle_event("keep", params, socket) do
    with {:ok, target} <- parse_target(params),
         {:ok, _keep} <- Rules.keep(target, socket.assigns.current_user) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not keep that."))}
    end
  end

  def handle_event("unkeep", %{"id" => id}, socket) do
    case Enum.find(Rules.list_keeps(), &(&1.id == id)) do
      nil ->
        {:noreply, load(socket)}

      keep ->
        :ok = Rules.unkeep(keep_target(keep))
        {:noreply, load(socket)}
    end
  end

  defp parse_target(%{"unit" => "season", "media-item-id" => id, "season-number" => season}) do
    case Integer.parse(season) do
      {n, ""} -> {:ok, {:season, id, n}}
      _ -> :error
    end
  end

  defp parse_target(%{"unit" => "episode", "media-item-id" => id, "episode-id" => episode_id}),
    do: {:ok, {:episode, id, episode_id}}

  defp parse_target(_), do: :error

  defp keep_target(%{episode_id: ep, media_item_id: id}) when not is_nil(ep),
    do: {:episode, id, ep}

  defp keep_target(%{season_number: s, media_item_id: id}) when not is_nil(s),
    do: {:season, id, s}

  defp keep_target(%{media_item_id: id}), do: {:show, id}

  defp load(socket) do
    cleanups = SmartSpace.upcoming(within_days: @within_days)
    keeps = Rules.list_keeps()
    labels = episode_labels(cleanups)
    now = DateTime.utc_now()

    rows = Enum.map(cleanups, &row(&1, labels, now))

    socket
    |> assign(:bytes_due, cleanups |> Enum.map(& &1.bytes) |> Enum.sum())
    |> assign(:last_run_at, SmartSpace.last_run_at())
    |> assign(:enabled?, rule_enabled?())
    |> assign(:upcoming_count, length(rows))
    |> assign(:keeps_count, length(keeps))
    |> stream(:upcoming, rows, reset: true)
    |> stream(:keeps, keeps, reset: true)
  end

  defp row(cleanup, labels, now) do
    first_episode = List.first(cleanup.episode_ids)

    %{
      id: "#{cleanup.media_item_id}-#{cleanup.season_number}-#{first_episode}",
      cleanup: cleanup,
      episode_id: first_episode,
      label: unit_label(cleanup, labels),
      due: due_label(cleanup.eligible_at, now)
    }
  end

  # One query for every episode-unit row on the page.
  defp episode_labels(cleanups) do
    ids = for %{unit: :episode, episode_ids: [id | _]} <- cleanups, do: id

    if ids == [] do
      %{}
    else
      from(e in Episode, where: e.id in ^ids, select: {e.id, e.season_number, e.episode_number})
      |> Repo.all()
      |> Map.new(fn {id, season, number} -> {id, episode_code(season, number)} end)
    end
  end

  defp unit_label(%{unit: :season, season_number: n}, _labels),
    do: gettext("Season %{number}", number: n)

  defp unit_label(%{unit: :episode, episode_ids: [id | _], season_number: season}, labels),
    do: Map.get(labels, id, episode_code(season, nil))

  defp episode_code(season, nil), do: "S#{pad(season)}"
  defp episode_code(season, number), do: "S#{pad(season)}E#{pad(number)}"

  defp pad(n), do: n |> to_string() |> String.pad_leading(2, "0")

  defp due_label(eligible_at, now) do
    seconds = DateTime.diff(eligible_at, now, :second)

    if seconds <= 0 do
      gettext("next run")
    else
      days = max(ceil(seconds / 86_400), 1)
      ngettext("in %{count} day", "in %{count} days", days)
    end
  end

  defp rule_enabled? do
    config = Mydia.Config.get().smart_space
    (config && config.enabled) || Enum.any?(Rules.list_overrides(), &(&1.mode == "custom"))
  end

  @doc false
  def keep_label(%{episode: %{} = ep}) when not is_nil(ep.id),
    do: episode_code(ep.season_number, ep.episode_number)

  def keep_label(%{season_number: n}) when not is_nil(n),
    do: gettext("Season %{number}", number: n)

  def keep_label(_), do: gettext("Whole show")

  @doc false
  def size(bytes), do: format_file_size(bytes)
end
