defmodule Mydia.SmartSpace.Loader do
  @moduledoc """
  Builds `Mydia.SmartSpace.Inputs` from the database for the pure evaluator.

  Each table is read once with a filter on the selected show ids, so the query
  count does not grow with the number of shows.

  Decisions worth knowing:

    * Every episode row of a loaded show is passed, monitored or not, with or
      without files: the evaluator needs unaired episodes to hold a season back.
    * Files are `MediaFile.versions/0` (untrashed, `extra_kind` nil). Extras
      (samples, trailers) are not episode content, so the automation neither
      counts nor trashes them.
    * `watches` holds only the show's own playback rows, including episodes
      whose files are trashed. Rows without an episode are ignored.
  """

  import Ecto.Query

  alias Mydia.Accounts.User
  alias Mydia.Downloads.Download
  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Playback.Progress
  alias Mydia.Repo
  alias Mydia.SmartSpace.Inputs
  alias Mydia.SmartSpace.Inputs.{KeepRef, Show, Watch}
  alias Mydia.SmartSpace.{Keep, Override}

  @doc """
  Loads the evaluator inputs.

  Options: `:media_item_id` narrows to one show (included even when the global
  rule is off, so the show page can display its effective rule); `:config`
  overrides `Mydia.Config.get().smart_space`.
  """
  @spec load(keyword()) :: Inputs.t()
  def load(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> Mydia.Config.get().smart_space end)
    overrides = load_overrides(opts[:media_item_id])
    items = select_items(config, overrides, opts[:media_item_id])
    ids = Enum.map(items, & &1.id)

    episodes = load_episodes(ids)
    files = load_files(ids)
    {ep_flight, show_flight} = load_in_flight(ids)
    keeps = load_keeps(ids)
    watches = load_watches(ids)

    shows =
      Enum.map(items, fn item ->
        %Show{
          media_item_id: item.id,
          title: item.title,
          override: override_map(overrides[item.id]),
          episodes:
            for ep <- Map.get(episodes, item.id, []) do
              %Inputs.Episode{
                id: ep.id,
                season_number: ep.season_number,
                episode_number: ep.episode_number,
                air_date: ep.air_date,
                files: Map.get(files, ep.id, []),
                monitored: ep.monitored != false,
                in_flight?: MapSet.member?(ep_flight, ep.id)
              }
            end,
          keeps: Map.get(keeps, item.id, []),
          watches: Map.get(watches, item.id, []),
          in_flight_show?: MapSet.member?(show_flight, item.id)
        }
      end)

    %Inputs{
      global: %{
        enabled: config.enabled,
        unit: config.unit,
        grace_days: config.grace_days,
        watched_by: config.watched_by
      },
      selected_user_ids: selected_user_ids(config),
      shows: shows
    }
  end

  defp load_overrides(nil), do: Map.new(Repo.all(Override), &{&1.media_item_id, &1})

  defp load_overrides(id),
    do:
      Map.new(
        Repo.all(from o in Override, where: o.media_item_id == ^id),
        &{&1.media_item_id, &1}
      )

  defp override_map(nil), do: nil

  defp override_map(%Override{} = o), do: %{mode: o.mode, unit: o.unit, grace_days: o.grace_days}

  defp select_items(config, overrides, media_item_id) do
    base = from(m in MediaItem, where: m.type == "tv_show", order_by: [asc: m.title, asc: m.id])

    cond do
      media_item_id != nil ->
        Repo.all(from m in base, where: m.id == ^media_item_id)

      config.enabled ->
        off = for {id, %Override{mode: "off"}} <- overrides, do: id
        Repo.all(from m in base, where: m.id not in ^off)

      true ->
        custom = for {id, %Override{mode: "custom"}} <- overrides, do: id
        Repo.all(from m in base, where: m.id in ^custom)
    end
  end

  defp selected_user_ids(%{watched_by: "selected", selected_users: names}) do
    names = names || []
    users = Repo.all(from u in User, where: u.username in ^names, select: {u.username, u.id})
    by_name = Map.new(users)

    if Enum.all?(names, &Map.has_key?(by_name, &1)),
      do: Enum.map(names, &Map.fetch!(by_name, &1)),
      else: :misconfigured
  end

  defp selected_user_ids(_), do: []

  # %{media_item_id => [{episode, media_item_id}]}
  defp load_episodes([]), do: %{}

  defp load_episodes(ids) do
    from(e in Episode,
      where: e.media_item_id in ^ids,
      order_by: [asc: e.season_number, asc: e.episode_number, asc: e.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.media_item_id)
  end

  defp load_files([]), do: %{}

  defp load_files(ids) do
    from(mf in MediaFile.versions(),
      join: e in Episode,
      on: e.id == mf.episode_id,
      where: e.media_item_id in ^ids,
      order_by: [asc: mf.inserted_at, asc: mf.id],
      select: {mf.episode_id, mf.id, mf.size}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_e, id, size} -> {id, size} end)
  end

  defp load_in_flight([]), do: {MapSet.new(), MapSet.new()}

  defp load_in_flight(ids) do
    # Nothing ties downloads.episode_id to downloads.media_item_id, so match an
    # episode download through either column.
    rows =
      from(d in Download.occupying(),
        left_join: e in Episode,
        on: e.id == d.episode_id,
        where: d.media_item_id in ^ids or e.media_item_id in ^ids,
        select: {d.media_item_id, d.episode_id, e.media_item_id}
      )
      |> Repo.all()

    eps = for {_m, e, _em} when not is_nil(e) <- rows, into: MapSet.new(), do: e

    shows =
      for {m, nil, _} <- rows, m in ids, into: MapSet.new(), do: m

    {eps, shows}
  end

  defp load_keeps([]), do: %{}

  defp load_keeps(ids) do
    from(k in Keep, where: k.media_item_id in ^ids, order_by: [asc: k.inserted_at, asc: k.id])
    |> Repo.all()
    |> Enum.group_by(& &1.media_item_id, &keep_ref/1)
  end

  defp keep_ref(%Keep{episode_id: e}) when not is_nil(e),
    do: %KeepRef{level: :episode, episode_id: e}

  defp keep_ref(%Keep{season_number: s}) when not is_nil(s),
    do: %KeepRef{level: :season, season_number: s}

  defp keep_ref(%Keep{}), do: %KeepRef{level: :show}

  defp load_watches([]), do: %{}

  defp load_watches(ids) do
    from(p in Progress,
      join: e in Episode,
      on: e.id == p.episode_id,
      where: e.media_item_id in ^ids,
      order_by: [asc: p.inserted_at, asc: p.id],
      select: {e.media_item_id, p.user_id, p.episode_id, p.watched, p.last_watched_at}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_m, u, e, w, at} ->
      %Watch{user_id: u, episode_id: e, watched: w == true, last_watched_at: at}
    end)
  end
end
