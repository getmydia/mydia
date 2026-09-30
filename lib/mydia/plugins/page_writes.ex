defmodule Mydia.Plugins.PageWrites do
  @moduledoc """
  Executes one plugin page write as a user, and undoes it.

  Every op takes host-resolved, string-keyed `args` and returns
  `{:ok, result, inverse}`. `inverse` is what `undo/6` needs, `:noop` when
  nothing changed (not journaled), or `:irreversible`. Undo compares the current
  state against the state the write left behind and returns `{:error, :conflict}`
  rather than overwriting a later change.

  Conflict detection compares the fields the write set against the values it
  recorded, never `updated_at`: a timestamp also moves for the write itself and
  for unrelated bookkeeping, and is only second-resolution, so it cannot tell a
  genuine user change from noise.

  Nothing here knows about plugins beyond the `origin` tag used for echo
  suppression; grant checks happen in `Mydia.Plugins.PageActions`.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Accounts.User
  alias Mydia.Collections
  alias Mydia.Library
  alias Mydia.Media
  alias Mydia.MediaRequests
  alias Mydia.Playback
  alias Mydia.Plugins.Error

  @surfaces %{
    "watch_state" => "playback:watched",
    "favorite_add" => "collections:favorite",
    "collection_create" => "collections:write",
    "collection_update" => "collections:write",
    "collection_add_items" => "collections:write",
    "collection_remove_items" => "collections:write",
    "media_request" => "media:add",
    "media_add" => "media:add"
  }

  # The collection fields a page may set, and so the fields conflict detection
  # compares.
  @collection_fields ~w(name description smart_rules)

  @type inverse :: map() | :noop | :irreversible

  @spec surface(String.t()) :: String.t()
  def surface(op), do: Map.fetch!(@surfaces, op)

  @spec execute(String.t(), map(), User.t(), String.t()) ::
          {:ok, map(), inverse()} | {:error, Error.t()}
  def execute("watch_state", args, user, origin) do
    content = content_kw(args["content"])
    prior = progress_snapshot(user.id, content)

    with :ok <- write_watch(user.id, content, args, origin) do
      post = progress_snapshot(user.id, content)
      {:ok, %{"status" => "changed"}, %{"prior" => prior, "post" => post}}
    end
  end

  def execute("favorite_add", %{"media_item_id" => id}, user, _origin) do
    if Collections.is_favorite?(Scope.for_user(user), id) do
      {:ok, %{"status" => "already-favorited"}, :noop}
    else
      with {:ok, favorites} <- Collections.get_or_create_favorites(user),
           {:ok, _} <- Collections.add_item(favorites, id) do
        {:ok, %{"status" => "changed"}, %{"media_item_id" => id}}
      else
        _ -> {:error, Error.new(:internal, "could not add favorite")}
      end
    end
  end

  def execute("collection_create", args, user, _origin) do
    attrs =
      args
      |> Map.take(~w(name description type smart_rules))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Collections.create_collection(user, attrs) do
      {:ok, c} ->
        {:ok, %{"id" => c.id},
         %{"id" => c.id, "after" => collection_snapshot(c, @collection_fields)}}

      {:error, reason} ->
        {:error, write_error("collection-create", reason)}
    end
  end

  def execute("collection_update", %{"id" => id, "attrs" => attrs}, user, _origin) do
    attrs = Map.take(attrs, @collection_fields)
    keys = Map.keys(attrs)

    with {:ok, c} <- owned_collection(user, id),
         prior = collection_snapshot(c, keys),
         {:ok, updated} <- Collections.update_collection(user, c, attrs) do
      {:ok, %{"id" => id}, %{"prior" => prior, "after" => collection_snapshot(updated, keys)}}
    else
      {:error, %Error{} = e} -> {:error, e}
      {:error, reason} -> {:error, write_error("collection-update", reason)}
    end
  end

  def execute("collection_add_items", %{"id" => id, "media_item_ids" => ids}, user, _origin) do
    with {:ok, c} <- manual_collection(user, id) do
      present = Collections.item_ids_in(c, ids)
      added = ids |> Enum.uniq() |> Enum.reject(&MapSet.member?(present, &1))

      case added do
        [] ->
          {:ok, %{"added" => 0}, :noop}

        _ ->
          case Collections.add_items(c, added) do
            {:ok, _count} -> {:ok, %{"added" => length(added)}, %{"media_item_ids" => added}}
            {:error, reason} -> {:error, write_error("collection-add-items", reason)}
          end
      end
    end
  end

  def execute("collection_remove_items", %{"id" => id, "media_item_ids" => ids}, user, _origin) do
    with {:ok, c} <- manual_collection(user, id) do
      removed = c |> Collections.item_ids_in(ids) |> MapSet.to_list()
      Enum.each(removed, &Collections.remove_item(c, &1))

      if removed == [],
        do: {:ok, %{"removed" => 0}, :noop},
        else: {:ok, %{"removed" => length(removed)}, %{"media_item_ids" => removed}}
    end
  end

  def execute("media_request", args, user, _origin) do
    attrs = %{
      media_type: args["media_type"],
      title: args["title"],
      year: args["year"],
      tmdb_id: args["tmdb_id"],
      tvdb_id: args["tvdb_id"],
      requester_id: user.id
    }

    case MediaRequests.create_request(Scope.for_user(user), attrs) do
      {:ok, request} -> {:ok, %{"request_id" => request.id}, %{"request_id" => request.id}}
      {:error, :duplicate_request} -> {:ok, %{"status" => "already-requested"}, :noop}
      {:error, :duplicate_media} -> {:ok, %{"status" => "already-in-library"}, :noop}
      {:error, reason} -> {:error, write_error("media-request", reason)}
    end
  end

  def execute("media_add", args, user, _origin) do
    type = media_type_atom(args["media_type"])
    ref = {provider_atom(args["provider"]), args["provider_id"]}
    scope = Scope.for_user(user)
    defaults = Media.AddDefaults.resolve(user, type)

    case Media.Add.from_provider(scope, ref, type, nil, Media.AddDefaults.to_add_opts(defaults)) do
      {:ok, item} ->
        Mydia.Search.maybe_queue_search(item, defaults.search_on_add)
        {:ok, %{"media_item_id" => item.id}, %{"media_item_id" => item.id}}

      {:error, {:already_in_library, item}} ->
        with {:ok, _} <- MediaRequests.auto_approve_matching_requests(item, []) do
          {:ok, %{"media_item_id" => item.id, "status" => "already-in-library"}, :noop}
        else
          {:error, reason} -> {:error, write_error("media-add", reason)}
        end

      {:error, reason} ->
        {:error, write_error("media-add", reason)}
    end
  end

  @spec undo(String.t(), map(), map(), map() | :noop | :irreversible, User.t(), String.t()) ::
          :ok | {:error, :conflict | :irreversible | Error.t()}
  def undo(_op, _args, _result, :irreversible, _user, _origin), do: {:error, :irreversible}

  def undo("watch_state", args, _result, %{"prior" => prior, "post" => post}, user, origin) do
    content = content_kw(args["content"])

    if progress_snapshot(user.id, content) != post do
      {:error, :conflict}
    else
      restore_progress(user.id, content, prior, origin)
    end
  end

  def undo("favorite_add", _args, _result, %{"media_item_id" => id}, user, _origin) do
    with {:ok, favorites} <- Collections.get_or_create_favorites(user) do
      case Collections.remove_item(favorites, id) do
        {:ok, _} -> :ok
        {:error, :not_found} -> {:error, :conflict}
        {:error, _} -> {:error, Error.new(:internal, "could not remove favorite")}
      end
    end
  end

  # Deleting is only safe while the collection is still what the write made it:
  # the fields it set are unchanged and, for a manual collection, nothing has
  # been put in it since.
  def undo(
        "collection_create",
        _args,
        _result,
        %{"id" => id, "after" => after_state},
        user,
        _origin
      ) do
    with {:ok, c} <- owned_conflict(user, id),
         :ok <- unchanged(c, after_state),
         :ok <- empty_if_manual(user, c),
         {:ok, _} <- Collections.delete_collection(user, c) do
      :ok
    else
      {:error, :conflict} -> {:error, :conflict}
      {:error, _} -> {:error, Error.new(:internal, "could not delete collection")}
    end
  end

  def undo(
        "collection_update",
        %{"id" => id},
        _result,
        %{"prior" => prior, "after" => after_state},
        user,
        _origin
      ) do
    with {:ok, c} <- owned_conflict(user, id),
         :ok <- unchanged(c, after_state),
         {:ok, _} <- Collections.update_collection(user, c, prior) do
      :ok
    else
      {:error, :conflict} -> {:error, :conflict}
      {:error, _} -> {:error, Error.new(:internal, "could not restore collection")}
    end
  end

  def undo(
        "collection_add_items",
        %{"id" => id},
        _result,
        %{"media_item_ids" => added},
        user,
        _origin
      ) do
    with {:ok, c} <- manual_collection(user, id) do
      if MapSet.size(Collections.item_ids_in(c, added)) != length(added) do
        {:error, :conflict}
      else
        Enum.each(added, &Collections.remove_item(c, &1))
        :ok
      end
    end
  end

  def undo(
        "collection_remove_items",
        %{"id" => id},
        _result,
        %{"media_item_ids" => removed},
        user,
        _origin
      ) do
    with {:ok, c} <- manual_collection(user, id) do
      if MapSet.size(Collections.item_ids_in(c, removed)) != 0 do
        {:error, :conflict}
      else
        with {:ok, _} <- Collections.add_items(c, removed), do: :ok
      end
    end
  end

  def undo("media_request", _args, _result, %{"request_id" => rid}, user, _origin) do
    case [requester_id: user.id] |> MediaRequests.list_requests() |> Enum.find(&(&1.id == rid)) do
      nil ->
        {:error, :conflict}

      request ->
        case MediaRequests.cancel_request(Scope.for_user(user), request) do
          {:ok, _} -> :ok
          {:error, :not_pending} -> {:error, :irreversible}
          {:error, :unauthorized} -> {:error, :conflict}
        end
    end
  end

  def undo("media_add", _args, _result, %{"media_item_id" => id}, user, _origin) do
    scope = Scope.for_user(user)

    with {:ok, item} <- fetch_media_item(scope, id) do
      if Library.list_media_files(media_item_id: id) != [] do
        {:error, :irreversible}
      else
        case Media.delete_media_item(scope, item) do
          {:ok, _item, _disk} -> :ok
          {:error, _} -> {:error, Error.new(:internal, "could not remove media item")}
        end
      end
    end
  end

  # ── helpers ──

  defp fetch_media_item(scope, id) do
    {:ok, Media.get_media_item!(scope, id)}
  rescue
    Ecto.NoResultsError -> {:error, :conflict}
  end

  defp content_kw(%{"media_item_id" => id}), do: [media_item_id: id]
  defp content_kw(%{"episode_id" => id}), do: [episode_id: id]

  defp progress_snapshot(user_id, content) do
    case Playback.get_progress(user_id, content) do
      nil ->
        nil

      p ->
        %{
          "watched" => p.watched == true,
          "position_seconds" => p.position_seconds,
          "duration_seconds" => p.duration_seconds
        }
    end
  end

  # Mirrors HostFunctions.apply_watch_state/5: an explicit position is
  # authoritative; otherwise mark watched, or clear progress to unwatch.
  defp write_watch(user_id, content, args, origin) do
    position = args["position_seconds"]
    watched = args["watched"] == true

    cond do
      is_integer(position) ->
        attrs = %{
          position_seconds: position,
          duration_seconds: args["duration_seconds"],
          watched: watched
        }

        case Playback.save_progress(user_id, content, attrs,
               origin: origin,
               authoritative_watched: true
             ) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, Error.new(:invalid_request, "could not save progress")}
        end

      watched ->
        Playback.ensure_watched(user_id, content, origin: origin)
        :ok

      true ->
        case Playback.delete_progress(user_id, content, origin: origin) do
          {:ok, _} -> :ok
          {:error, :not_found} -> :ok
        end
    end
  end

  defp restore_progress(user_id, content, nil, origin) do
    case Playback.delete_progress(user_id, content, origin: origin) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restore_progress(user_id, content, prior, origin) do
    attrs = %{
      position_seconds: prior["position_seconds"],
      duration_seconds: prior["duration_seconds"],
      watched: prior["watched"]
    }

    case Playback.save_progress(user_id, content, attrs,
           origin: origin,
           authoritative_watched: true
         ) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, Error.new(:internal, "could not restore progress")}
    end
  end

  defp owned_collection(user, id) do
    case Collections.get_collection(user, id) do
      %{user_id: uid} = c when uid == user.id -> {:ok, c}
      _ -> {:error, Error.new(:not_found, "collection #{id} not found")}
    end
  end

  # For undo, a collection that is gone or no longer ours is a conflict, not a
  # not-found: the state the write left behind no longer exists.
  defp owned_conflict(user, id) do
    case owned_collection(user, id) do
      {:ok, c} -> {:ok, c}
      {:error, _} -> {:error, :conflict}
    end
  end

  defp manual_collection(user, id) do
    case owned_collection(user, id) do
      {:ok, %{type: "manual"} = c} ->
        {:ok, c}

      {:ok, _smart} ->
        {:error, Error.new(:invalid_request, "smart collections have no manual items")}

      error ->
        error
    end
  end

  # JSON-normalized so a value read back from the journal compares equal to one
  # read from the row (atom vs string keys inside smart_rules).
  defp collection_snapshot(collection, keys) do
    keys
    |> Map.new(&{&1, Map.get(collection, String.to_existing_atom(&1))})
    |> json_normalize()
  end

  defp json_normalize(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp unchanged(collection, recorded) do
    if collection_snapshot(collection, Map.keys(recorded)) == json_normalize(recorded),
      do: :ok,
      else: {:error, :conflict}
  end

  defp empty_if_manual(user, %{type: "manual"} = c) do
    if Collections.item_count(Scope.for_user(user), c) > 0, do: {:error, :conflict}, else: :ok
  end

  defp empty_if_manual(_user, _smart), do: :ok

  defp media_type_atom("movie"), do: :movie
  defp media_type_atom("tv_show"), do: :tv_show

  defp provider_atom("tmdb"), do: :tmdb
  defp provider_atom("tvdb"), do: :tvdb

  defp write_error(op, %Ecto.Changeset{} = cs),
    do: Error.new(:invalid_request, "#{op}: #{inspect(cs.errors)}")

  defp write_error(op, reason), do: Error.new(:invalid_request, "#{op}: #{inspect(reason)}")
end
