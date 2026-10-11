defmodule Mydia.ImportCandidates do
  @moduledoc """
  Persistence and review operations for durable import candidates.

  There is no persisted rollup table behind a "group" here. A group is
  `Mydia.Library.ImportCandidateGroup`, computed on every read by
  `group_query/2` aggregating `import_candidates` rows for one library path.
  That is what makes review decisions durable while grouping stays free: a
  candidate carries its own `dismissed_at`, and a group simply stops existing
  the moment its last candidate is dismissed, promoted, or deleted -- there is
  no separate row to keep in sync.

  This module is the public API; each function delegates to a focused
  submodule: `Store` (persistence and demotion), `Review` (the grouped read
  model), `Edits` (dismiss, restore and match changes), `AcceptQueue`,
  `Rematch`, `Deletion` (the queued operations and their drains) and
  `LocalShows`.
  """

  alias Mydia.ImportCandidates.{
    AcceptQueue,
    Deletion,
    Edits,
    LocalShows,
    Rematch,
    Review,
    Store
  }

  @type cursor :: {non_neg_integer(), String.t()}

  ## Store

  defdelegate upsert(attrs), to: Store
  defdelegate get_by_path(library_path_id, relative_path), to: Store
  defdelegate return_to_review(file, actor_id), to: Store
  defdelegate delete_missing(library_path_id, relative_paths, opts \\ []), to: Store
  defdelegate demote_episode_files(episode, opts \\ []), to: Store
  defdelegate demote_movie_files(movie, opts \\ []), to: Store
  defdelegate stage_item_file(item, library_path, attrs), to: Store

  @doc false
  defdelegate provider_identity(item), to: Store

  ## Review

  defdelegate auto_accept_threshold(), to: Review
  defdelegate band(group), to: Review
  defdelegate group_query(library_path_id, opts \\ []), to: Review

  @doc false
  defdelegate escape_like(term), to: Review

  defdelegate page(library_path_id, opts \\ []), to: Review
  defdelegate get_group(library_path_id, anchor_key, opts \\ []), to: Review
  defdelegate band_counts(library_path_id), to: Review
  defdelegate count_pending(), to: Review
  defdelegate count_by_status(library_path_id, status), to: Review
  defdelegate members(library_path_id, anchor_key), to: Review
  defdelegate member_count(library_path_id, anchor_key), to: Review
  defdelegate outstanding(library_path_id, limit, opts \\ []), to: Review
  defdelegate count_outstanding(library_path_id), to: Review

  ## Edits

  defdelegate dismiss(scope), to: Edits
  defdelegate restore(scope), to: Edits
  defdelegate change_match(library_path_id, anchor_key, match), to: Edits
  defdelegate update_member_episode(candidate_id, season, episode), to: Edits

  ## Accept queue

  defdelegate queue_accept(scope, opts \\ []), to: AcceptQueue
  defdelegate queue_accept_all_matched(library_path_id), to: AcceptQueue
  defdelegate drain_accepted(library_path_id, opts \\ []), to: AcceptQueue

  ## Rematch

  defdelegate queue_rematch(scope), to: Rematch
  defdelegate drain_rematch(library_path_id, opts \\ []), to: Rematch

  ## Deletion

  defdelegate queue_delete(scope, opts \\ []), to: Deletion
  defdelegate queue_delete_candidate(candidate_id), to: Deletion
  defdelegate count_files(scope), to: Deletion
  defdelegate drain_delete(library_path_id, opts \\ []), to: Deletion

  ## Local shows

  defdelegate clear_for_library(library_path_id), to: LocalShows
  defdelegate create_local_show(library_path_id, anchor_key), to: LocalShows
end
