defmodule Mydia.Jobs.ApplyImportGroups do
  @moduledoc """
  Commits accepted import groups.

  Runs on `:default` rather than `:imports`, which has concurrency 1 and is held
  for the duration of a library scan. An accept queued behind a multi-hour run
  would look like the button did nothing.

  One transaction per group, never one for the batch. On SQLite a single
  transaction over a whole batch holds the global write lock and blocks the
  scanner; on Postgres it overflows the 64-entry subxid cache. Per-group also
  means a crash loses at most one group's progress, and `unresolved_count` tells
  a restarted job where it got to.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Mydia.ImportGroups
  alias Mydia.Library.{FileIngest, ImportGroup}
  alias Mydia.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id}}) do
    library_path_id
    |> accepted_groups()
    |> Enum.each(&apply_group/1)

    broadcast(library_path_id)

    :ok
  end

  defp accepted_groups(library_path_id) do
    ImportGroup
    |> where([g], g.library_path_id == ^library_path_id and g.status == "accepted")
    |> order_by([g], desc: g.file_count, asc: g.id)
    |> Repo.all()
  end

  @member_page 1_000

  defp apply_group(%ImportGroup{} = group) do
    remaining = drain(group, ImportGroups.member_count(group.id))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    status = if remaining == 0, do: "applied", else: "accepted"

    group
    |> Ecto.Changeset.change(unresolved_count: remaining, status: status, updated_at: now)
    |> Repo.update!()
  rescue
    error ->
      Logger.error("Applying an import group failed, leaving it accepted for retry",
        import_group_id: group.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end

  # Members come back one bounded page at a time, so a group larger than a page
  # has to be drained rather than swept once. Without this loop a group with
  # more members than @member_page ingests its first page, keeps `accepted`
  # status because members remain, and then stalls forever: nothing re-enqueues
  # the job.
  #
  # One transaction per page, never one for the group: on SQLite a single
  # transaction over a whole show holds the global write lock for its duration.
  defp drain(group, remaining_before) do
    Repo.transaction(fn ->
      group.id
      |> ImportGroups.members(limit: @member_page)
      |> Enum.each(&ingest_member(&1, group))
    end)

    remaining = ImportGroups.member_count(group.id)

    cond do
      remaining == 0 ->
        0

      remaining < remaining_before ->
        drain(group, remaining)

      # No progress: every member of that page failed to link, so another pass
      # would fetch the same rows and fail identically. Stop and leave the group
      # `accepted` so a later run can retry it, rather than spinning.
      true ->
        remaining
    end
  end

  defp ingest_member(%{media_file: media_file, candidate: nil}, _group) do
    Logger.debug("Skipping a group member with no candidate", media_file_id: media_file.id)
    :ok
  end

  defp ingest_member(%{media_file: media_file, candidate: candidate}, group) do
    match = %{
      provider_id: candidate.provider_id || group.provider_id,
      provider_type: provider_type(candidate, group),
      title: candidate.title || group.suggested_title,
      year: candidate.year || group.suggested_year,
      match_confidence: candidate.confidence || group.min_confidence || 1.0,
      parsed_info: parsed_info(candidate, group)
    }

    media_file = Repo.preload(media_file, :library_path)

    FileIngest.ingest(media_file, match, policy: :create_items)
  end

  defp provider_type(%{provider_type: type}, _group) when is_binary(type),
    do: String.to_existing_atom(type)

  defp provider_type(_, %{provider_type: type}) when is_binary(type),
    do: String.to_existing_atom(type)

  defp provider_type(_, _), do: :tvdb

  # `candidate.parsed_info` round-trips through JSON (`MatchCandidate`'s
  # `parsed_info` column is `Mydia.Settings.JsonMapType`), so its keys and its
  # "type" value are strings. `MetadataEnricher.determine_media_type/1`
  # pattern-matches on `%{parsed_info: %{type: :movie}}` / `%{type: :tv_show}}`
  # with atom keys and an atom value, so handing the stored map through
  # unchanged never matches either clause and silently falls through to the
  # movie default for every file, regardless of the group's real media type.
  # This rebuilds the atom-keyed shape `FileIngest`/`MetadataEnricher` expect
  # (see `test/mydia/library/file_ingest_test.exs`'s `match/1` and
  # `local_tv_match/2` helpers).
  defp parsed_info(candidate, group) do
    stored = candidate.parsed_info || %{}

    %{
      type: media_type_atom(candidate.media_type || group.media_type),
      season: Map.get(stored, "season"),
      episodes: Map.get(stored, "episodes") || []
    }
  end

  defp media_type_atom("tv_show"), do: :tv_show
  defp media_type_atom(_), do: :movie

  defp broadcast(library_path_id) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "import_groups:#{library_path_id}",
      {:import_groups_changed, library_path_id}
    )
  end
end
