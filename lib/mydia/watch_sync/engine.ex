defmodule Mydia.WatchSync.Engine do
  @moduledoc """
  Drives one provider through one sync for one user.

  Provider-agnostic: everything Plex-specific lives behind the
  `Mydia.WatchSync.Provider` behaviour. Every merge decision comes from
  `Mydia.WatchSync.Reconciler`, which is pure. This module owns all the I/O.
  """

  import Ecto.Query

  alias Mydia.Media
  alias Mydia.Playback
  alias Mydia.Repo
  alias Mydia.WatchSync.Mapping
  alias Mydia.WatchSync.Reconciler
  alias Mydia.WatchSync.State

  require Logger

  @empty_counts %{imported: 0, exported: 0, not_found: 0, unchanged: 0}

  @spec sync(module(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync(provider_mod, instance, user_scope, opts) do
    provider = Keyword.fetch!(opts, :provider)
    instance_id = to_string(instance.id)
    origin = "sync:#{provider}"

    with :ok <- maybe_refresh(provider_mod, instance, provider, instance_id, opts),
         cursor = cursor(user_scope.user_id, provider, instance_id),
         {:ok, changes} <- provider_mod.list_changes(instance, user_scope, cursor) do
      index = mapping_index(provider, instance_id)

      counts =
        Enum.reduce(changes, @empty_counts, fn change, acc ->
          case Map.get(index, change.remote_id) do
            nil ->
              bump(acc, :not_found)

            content_id ->
              reconcile_one(
                provider_mod,
                instance,
                user_scope,
                {provider, instance_id, origin},
                content_id,
                change,
                acc
              )
          end
        end)

      {:ok, counts}
    end
  end

  # ── Mapping refresh ────────────────────────────────────────────────

  # The full crawl is the expensive call, so it runs on a first sync or on
  # explicit demand, never on every tick.
  defp maybe_refresh(provider_mod, instance, provider, instance_id, opts) do
    case Keyword.get(opts, :refresh_mappings, :auto) do
      :skip ->
        :ok

      :force ->
        do_refresh(provider_mod, instance, provider, instance_id)

      :auto ->
        if mapped_any?(provider, instance_id),
          do: :ok,
          else: do_refresh(provider_mod, instance, provider, instance_id)
    end
  end

  defp do_refresh(provider_mod, instance, provider, instance_id) do
    with {:ok, mappings} <- provider_mod.refresh_mappings(instance, []) do
      Enum.each(mappings, fn mapping ->
        case resolve_local(mapping) do
          nil -> :ok
          content_id -> upsert_mapping(provider, instance_id, content_id, mapping.remote_id)
        end
      end)

      :ok
    end
  end

  defp resolve_local(%{type: :movie} = mapping) do
    case Media.find_by_external_ids(mapping.external_ids) do
      nil -> nil
      item -> [media_item_id: item.id]
    end
  end

  defp resolve_local(%{type: :episode} = mapping) do
    with %{id: show_id} <- Media.find_by_external_ids(mapping.external_ids),
         %{id: ep_id} <-
           Media.find_episode(show_id, mapping.season_number, mapping.episode_number) do
      [episode_id: ep_id]
    else
      _ -> nil
    end
  end

  defp upsert_mapping(provider, instance_id, content_id, remote_id) do
    attrs =
      content_id
      |> Enum.into(%{})
      |> Map.merge(%{
        provider: provider,
        provider_instance_id: instance_id,
        remote_id: remote_id,
        last_seen_at: now()
      })

    %Mapping{}
    |> Mapping.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:remote_id, :last_seen_at, :updated_at]},
      conflict_target: mapping_conflict_target(content_id)
    )
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("mapping upsert failed: #{inspect(reason)}")
    end

    :ok
  end

  defp mapping_conflict_target(media_item_id: _),
    do: [:provider, :provider_instance_id, :media_item_id]

  defp mapping_conflict_target(episode_id: _),
    do: [:provider, :provider_instance_id, :episode_id]

  defp mapped_any?(provider, instance_id) do
    Mapping
    |> where([m], m.provider == ^provider and m.provider_instance_id == ^instance_id)
    |> limit(1)
    |> Repo.exists?()
  end

  defp mapping_index(provider, instance_id) do
    Mapping
    |> where([m], m.provider == ^provider and m.provider_instance_id == ^instance_id)
    |> Repo.all()
    |> Map.new(fn m ->
      content_id =
        if m.episode_id, do: [episode_id: m.episode_id], else: [media_item_id: m.media_item_id]

      {m.remote_id, content_id}
    end)
  end

  # ── Reconciliation ─────────────────────────────────────────────────

  defp reconcile_one(
         provider_mod,
         instance,
         user_scope,
         {provider, instance_id, origin},
         content_id,
         change,
         acc
       ) do
    user_id = user_scope.user_id

    local = local_side(user_id, content_id)
    remote = %{watched: change.watched, position_seconds: change.position_seconds, at: change.at}
    state_row = get_state(user_id, provider, instance_id, content_id)

    case Reconciler.resolve(local, remote, snapshot_side(state_row)) do
      :noop ->
        bump(acc, :unchanged)

      {:pull, resolved} ->
        apply_local(user_id, content_id, resolved, remote.at, origin)
        put_state(state_row, user_id, provider, instance_id, content_id, resolved, remote.at)
        bump(acc, :imported)

      {:push, resolved} ->
        case provider_mod.apply_change(instance, user_scope, change.remote_id, resolved) do
          :ok ->
            put_state(state_row, user_id, provider, instance_id, content_id, resolved, remote.at)
            bump(acc, :exported)

          {:error, reason} ->
            Logger.warning("watch sync push failed: #{inspect(reason)}")
            acc
        end

      {:record_only, resolved} ->
        put_state(state_row, user_id, provider, instance_id, content_id, resolved, remote.at)
        bump(acc, :unchanged)
    end
  end

  # An absent progress row is not "no information": it is the state a local
  # unwatch leaves behind, since unwatching deletes the row outright.
  defp local_side(user_id, content_id) do
    case Playback.get_progress(user_id, content_id) do
      nil ->
        %{watched: false, position_seconds: nil, at: nil}

      progress ->
        %{
          watched: progress.watched,
          position_seconds: progress.position_seconds,
          at: progress.last_watched_at
        }
    end
  end

  defp snapshot_side(nil), do: nil

  defp snapshot_side(%State{} = state) do
    %{
      watched: state.synced_watched,
      position_seconds: state.synced_position_seconds,
      at: state.remote_last_watched_at
    }
  end

  defp apply_local(user_id, content_id, resolved, at, origin) do
    watched_at = at || now()

    cond do
      # Unwatch is a delete, matching Mydia's existing semantics. Detect it by
      # a currently-watched local row rather than by a nil position: Plex may
      # still report a leftover viewOffset on an unwatched item.
      resolved.watched == false and locally_watched?(user_id, content_id) ->
        case Playback.delete_progress(user_id, content_id, origin: origin) do
          {:ok, _} -> :ok
          {:error, :not_found} -> :ok
          other -> other
        end

      # Position present: write it authoritatively so the 90% auto-mark and the
      # "stamp now" default cannot diverge from the remote watched flag or at.
      not is_nil(resolved.position_seconds) ->
        Playback.save_progress(
          user_id,
          content_id,
          %{
            position_seconds: resolved.position_seconds,
            duration_seconds: duration_for(content_id, resolved.position_seconds),
            watched: resolved.watched,
            last_watched_at: watched_at
          },
          origin: origin,
          authoritative_watched: true
        )

        :ok

      resolved.watched ->
        Playback.ensure_watched(user_id, content_id, origin: origin, watched_at: watched_at)
        :ok

      true ->
        case Playback.delete_progress(user_id, content_id, origin: origin) do
          {:ok, _} -> :ok
          {:error, :not_found} -> :ok
          other -> other
        end
    end
  end

  defp locally_watched?(user_id, content_id) do
    case Playback.get_progress(user_id, content_id) do
      %{watched: true} -> true
      _ -> false
    end
  end

  # A duration is required by the changeset. Prefer the local runtime; fall back
  # to the position itself so the row is valid rather than fabricating 1 second,
  # which is what the previous implementation stored.
  defp duration_for(content_id, position_seconds) do
    case Playback.get_progress_duration(content_id) do
      nil -> max(position_seconds, 1)
      duration -> duration
    end
  end

  # ── Snapshot persistence ───────────────────────────────────────────

  defp get_state(user_id, provider, instance_id, content_id) do
    base =
      State
      |> where([s], s.user_id == ^user_id)
      |> where([s], s.provider == ^provider and s.provider_instance_id == ^instance_id)

    case content_id do
      [media_item_id: id] -> where(base, [s], s.media_item_id == ^id)
      [episode_id: id] -> where(base, [s], s.episode_id == ^id)
    end
    |> Repo.one()
  end

  defp put_state(existing, user_id, provider, instance_id, content_id, resolved, remote_at) do
    attrs =
      content_id
      |> Enum.into(%{})
      |> Map.merge(%{
        user_id: user_id,
        provider: provider,
        provider_instance_id: instance_id,
        synced_watched: resolved.watched,
        synced_position_seconds: resolved.position_seconds,
        synced_at: now(),
        remote_last_watched_at: remote_at
      })

    (existing || %State{})
    |> State.changeset(attrs)
    |> Repo.insert_or_update()
  end

  # Overlap window applied to the incremental cursor.
  #
  # `synced_at` is stamped when we write, not when the remote event happened. A
  # view that lands during a sync run (after we fetched its page, before the run
  # finishes) therefore carries a `lastViewedAt` earlier than the cursor we go on
  # to record, and a strictly-greater-than filter would skip it forever, since
  # the cursor only moves forward. Rewinding by more than a run's duration turns
  # that permanent loss into a little redundant work: re-examined items reconcile
  # to :noop because local, remote and snapshot already agree.
  @cursor_overlap_seconds 900

  defp cursor(user_id, provider, instance_id) do
    State
    |> where([s], s.user_id == ^user_id)
    |> where([s], s.provider == ^provider and s.provider_instance_id == ^instance_id)
    |> select([s], max(s.synced_at))
    |> Repo.one()
    |> case do
      nil -> nil
      %DateTime{} = at -> DateTime.add(at, -@cursor_overlap_seconds, :second)
    end
  end

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
