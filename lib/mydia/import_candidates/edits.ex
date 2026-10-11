defmodule Mydia.ImportCandidates.Edits do
  @moduledoc false

  import Ecto.Query

  alias Mydia.ImportCandidates.{Review, Store}
  alias Mydia.Library.ImportCandidate
  alias Mydia.Library.SelectionScope
  alias Mydia.Repo

  # --- Durable decisions -----------------------------------------------

  @doc """
  Dismisses a selection: stamps `dismissed_at` on every undismissed candidate
  in the selected anchors. Files are untouched.
  """
  @spec dismiss(SelectionScope.t()) :: {:ok, non_neg_integer()}
  def dismiss(%SelectionScope{} = scope) do
    now = Store.now()
    group_count = selected_group_count(scope)

    {row_count, _} =
      candidate_query(scope)
      |> where([c], is_nil(c.dismissed_at) and is_nil(c.queued_op))
      |> Repo.update_all(set: [dismissed_at: now, updated_at: now])

    if row_count > 0, do: Store.broadcast(scope.library_path_id)
    {:ok, if(row_count > 0, do: group_count, else: 0)}
  end

  @doc """
  Restores a selection: clears `dismissed_at` on every dismissed candidate in
  the selected anchors.
  """
  @spec restore(SelectionScope.t()) :: {:ok, non_neg_integer()}
  def restore(%SelectionScope{} = scope) do
    now = Store.now()
    group_count = selected_group_count(scope)

    {row_count, _} =
      candidate_query(scope)
      |> where([c], not is_nil(c.dismissed_at))
      |> Repo.update_all(set: [dismissed_at: nil, updated_at: now])

    if row_count > 0, do: Store.broadcast(scope.library_path_id)
    {:ok, if(row_count > 0, do: group_count, else: 0)}
  end

  @doc false
  def selected_group_count(scope) do
    scope
    |> SelectionScope.to_query()
    |> subquery()
    |> Repo.aggregate(:count)
  end

  # The row-level (ungrouped) query for a scope's selected anchors, built by
  # reusing `SelectionScope.to_query/1` -- an aggregate query already scoped
  # to the right anchor keys -- as a subquery of matching keys. This keeps a
  # `:filter`-mode selection to one bounded query regardless of how many
  # groups it covers: no candidate id, and no anchor key, is ever pulled into
  # a bind-parameter list here.
  @doc false
  def candidate_query(%SelectionScope{} = scope) do
    # `to_query/1` already carries a `select` (the aggregate map) -- Ecto
    # refuses a second `select` on the same query outright ("only one select
    # expression is allowed"), so the existing one has to be dropped before
    # this can reselect just the anchor key.
    anchor_keys =
      scope
      |> SelectionScope.to_query()
      |> exclude(:select)
      |> select([c], c.anchor_key)

    ImportCandidate
    |> where([c], c.library_path_id == ^scope.library_path_id)
    |> where([c], c.anchor_key in subquery(anchor_keys))
  end

  @doc """
  Applies a human-picked metadata match to every undismissed candidate in one
  anchor -- the "Change match" / "Identify" action.

  Each candidate's own `parsed_info` (season/episode) is left untouched; only
  the provider identity, title, year, media type, and confidence change.
  Confidence is set to 1.0: a human's pick is at least as trustworthy as an
  automatic match, and the point of a correction is that the group reads
  `:ready` afterwards.

  Returns `{:error, :not_found}` rather than raising when the anchor has no
  undismissed candidates left -- another session or a concurrent promotion can
  empty it between the page rendering the button and the reviewer clicking it.
  """
  @spec change_match(binary(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def change_match(library_path_id, anchor_key, match) do
    now = Store.now()
    match = stringify_match(match)

    {count, _} =
      ImportCandidate
      |> Review.for_anchor(library_path_id, anchor_key)
      |> Repo.update_all(
        set: [
          provider_id: match.provider_id,
          provider_type: match.provider_type,
          title: match.title,
          year: match.year,
          media_type: match.media_type,
          confidence: 1.0,
          last_error: nil,
          attempts: 0,
          next_retry_at: nil,
          updated_at: now
        ]
      )

    if count > 0 do
      Store.broadcast(library_path_id)
      {:ok, count}
    else
      {:error, :not_found}
    end
  end

  defp stringify_match(match) do
    %{
      provider_id: to_string(match.provider_id),
      provider_type: to_string(match.provider_type),
      title: match.title,
      year: match.year,
      media_type: to_string(match.media_type)
    }
  end

  @doc """
  Updates one candidate's assigned season and episode numbers.

  There is no group rollup to refresh: a group's `season_span` and
  `numbered_count` (as `Review.band/1` and `Review.group_query/2` see them) are computed
  fresh from `import_candidates` on every read, so nothing here needs
  invalidating.
  """
  @spec update_member_episode(
          binary(),
          integer() | String.t() | nil,
          integer() | String.t() | nil
        ) :: {:ok, ImportCandidate.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_member_episode(candidate_id, season, episode) do
    case Repo.get(ImportCandidate, candidate_id) do
      nil ->
        {:error, :not_found}

      candidate ->
        parsed_season = parse_int(season)
        episodes_list = if(ep = parse_int(episode), do: [ep], else: [])

        parsed_info =
          (candidate.parsed_info || %{})
          |> Map.put("season", parsed_season)
          |> Map.put("episodes", episodes_list)

        candidate
        |> ImportCandidate.changeset(%{parsed_info: parsed_info})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Store.broadcast(updated.library_path_id)
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {val, ""} -> val
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
