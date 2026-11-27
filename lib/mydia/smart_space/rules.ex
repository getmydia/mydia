defmodule Mydia.SmartSpace.Rules do
  @moduledoc """
  Per-show Smart Space overrides and keeps.
  """
  import Ecto.Query

  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo
  alias Mydia.SmartSpace.{Keep, Override}

  @type target ::
          {:show, binary()}
          | {:season, binary(), integer()}
          | {:episode, binary(), binary()}

  @doc "Returns the override row for a show, or nil when it inherits."
  def get_override(media_item_id), do: Repo.get_by(Override, media_item_id: media_item_id)

  @doc "All override rows."
  def list_overrides, do: Repo.all(Override)

  @doc """
  Sets a show's override. `mode: "inherit"` deletes the row and returns
  `{:ok, nil}`. Only TV shows may have an override.
  """
  def put_override(media_item_id, attrs) do
    if (attrs[:mode] || attrs["mode"]) == "inherit" do
      from(o in Override, where: o.media_item_id == ^media_item_id) |> Repo.delete_all()
      {:ok, nil}
    else
      upsert_override(media_item_id, attrs)
    end
  end

  defp upsert_override(media_item_id, attrs) do
    base = get_override(media_item_id) || %Override{media_item_id: media_item_id}

    changeset =
      base
      |> Override.changeset(attrs)
      |> validate_tv_show(media_item_id)

    Repo.insert_or_update(changeset)
  end

  defp validate_tv_show(%{valid?: false} = changeset, _id), do: changeset

  defp validate_tv_show(changeset, media_item_id) do
    case Repo.get(MediaItem, media_item_id) do
      %MediaItem{type: "tv_show"} ->
        changeset

      _ ->
        Ecto.Changeset.add_error(changeset, :media_item_id, "must be a TV show")
    end
  end

  @doc """
  Keeps a show, season or episode. Idempotent: a repeat returns the existing row.

  Returns `{:error, :invalid_target}` unless the media item is a TV show and the
  season or episode belongs to it.
  """
  @spec keep(target, struct() | nil) ::
          {:ok, Keep.t()} | {:error, Ecto.Changeset.t() | :invalid_target}
  def keep(target, user) do
    if valid_target?(target), do: do_keep(target, user), else: {:error, :invalid_target}
  end

  defp valid_target?(target) do
    id = elem(target, 1)

    with {:ok, _} <- Ecto.UUID.cast(id),
         %MediaItem{type: "tv_show"} <- Repo.get(MediaItem, id) do
      target_belongs?(target)
    else
      _ -> false
    end
  end

  defp target_belongs?({:show, _id}), do: true

  defp target_belongs?({:season, id, season}) when is_integer(season) do
    Repo.exists?(from e in Episode, where: e.media_item_id == ^id and e.season_number == ^season)
  end

  defp target_belongs?({:episode, id, episode_id}) do
    match?({:ok, _}, Ecto.UUID.cast(episode_id)) and
      Repo.exists?(from e in Episode, where: e.media_item_id == ^id and e.id == ^episode_id)
  end

  defp target_belongs?(_target), do: false

  defp do_keep(target, user) do
    Repo.transaction(fn ->
      case find_keep(target) do
        %Keep{} = existing ->
          existing

        nil ->
          struct = %Keep{created_by_id: user && user.id} |> put_target(target)

          case Repo.insert(Keep.changeset(struct)) do
            {:ok, keep} -> keep
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc "Removes the keep at a level. Missing keeps are fine."
  @spec unkeep(target) :: :ok
  def unkeep(target) do
    target |> keep_query() |> Repo.delete_all()
    :ok
  end

  @doc "Lists keeps with `:media_item` and `:episode` preloaded. `media_item_id:` narrows."
  def list_keeps(opts \\ []) do
    query = from(k in Keep, order_by: [asc: k.inserted_at, asc: k.id])

    query =
      case Keyword.get(opts, :media_item_id) do
        nil -> query
        id -> where(query, [k], k.media_item_id == ^id)
      end

    query |> Repo.all() |> Repo.preload([:media_item, :episode])
  end

  defp find_keep(target), do: target |> keep_query() |> Repo.one()

  defp keep_query({:show, id}) do
    from(k in Keep,
      where: k.media_item_id == ^id and is_nil(k.season_number) and is_nil(k.episode_id)
    )
  end

  defp keep_query({:season, id, season}) do
    from(k in Keep, where: k.media_item_id == ^id and k.season_number == ^season)
  end

  defp keep_query({:episode, id, episode_id}) do
    from(k in Keep, where: k.media_item_id == ^id and k.episode_id == ^episode_id)
  end

  defp put_target(keep, {:show, id}), do: %{keep | media_item_id: id}
  defp put_target(keep, {:season, id, s}), do: %{keep | media_item_id: id, season_number: s}
  defp put_target(keep, {:episode, id, e}), do: %{keep | media_item_id: id, episode_id: e}
end
