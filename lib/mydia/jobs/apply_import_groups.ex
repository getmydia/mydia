defmodule Mydia.Jobs.ApplyImportGroups do
  @moduledoc """
  Commits accepted import groups.

  Runs on `:default` rather than `:imports`, which has concurrency 1 and is held
  for the duration of a library scan. An accept queued behind a multi-hour run
  would look like the button did nothing.

  One transaction per page, never one for the group. On SQLite a single
  transaction over a whole group holds the global write lock for its duration
  and blocks the scanner; on Postgres it overflows the 64-entry subxid cache.
  Per-page also means a crash loses at most one page's progress, and
  `unresolved_count` tells a restarted job where it got to.

  `unique` is keyed on `library_path_id` alone (not the full args, so a custom
  `member_page` does not defeat it): `:default` runs at concurrency 5 with no
  other coordination between an accept and a still-draining previous run, and
  `accept/1`'s pending-guard only protects the `pending -> accepted`
  transition, not `accepted -> applied`. Without this, two jobs for the same
  library path can drain the same group concurrently.

  A group that does not reach `applied` — an ingest exception, a page that
  makes no progress — is reported back to Oban as a failure so `max_attempts`
  retries it, rather than stranding it `accepted` with nothing to re-enqueue
  the worker.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, keys: [:library_path_id], states: :incomplete]

  import Ecto.Query

  require Logger

  alias Mydia.ImportGroups
  alias Mydia.Library.{FileIngest, ImportGroup}
  alias Mydia.Repo

  @member_page 1_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id} = args}) do
    page = Map.get(args, "member_page", @member_page)

    stuck =
      library_path_id
      |> accepted_groups()
      |> Enum.map(&apply_group(&1, page))
      |> Enum.reject(&(&1 == :applied))

    broadcast(library_path_id)

    case stuck do
      [] -> :ok
      groups -> {:error, "#{length(groups)} import group(s) did not fully apply"}
    end
  end

  defp accepted_groups(library_path_id) do
    ImportGroup
    |> where([g], g.library_path_id == ^library_path_id and g.status == "accepted")
    |> order_by([g], desc: g.file_count, asc: g.id)
    |> Repo.all()
  end

  @spec apply_group(ImportGroup.t(), pos_integer()) :: :applied | :stuck
  defp apply_group(%ImportGroup{} = group, page) do
    remaining = drain(group, ImportGroups.member_count(group.id), page)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    status = if remaining == 0, do: "applied", else: "accepted"

    group
    |> Ecto.Changeset.change(unresolved_count: remaining, status: status, updated_at: now)
    |> Repo.update!()

    if status == "applied", do: :applied, else: :stuck
  rescue
    error ->
      Logger.error("Applying an import group failed, leaving it accepted for retry",
        import_group_id: group.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :stuck
  end

  # Members come back one bounded page at a time, so a group larger than a page
  # has to be drained rather than swept once. Without this loop a group with
  # more members than @member_page ingests its first page, keeps `accepted`
  # status because members remain, and then stalls forever: nothing re-enqueues
  # the job.
  #
  # One transaction per page, never one for the group: on SQLite a single
  # transaction over a whole show holds the global write lock for its duration.
  defp drain(group, remaining_before, page) do
    commit_page(group, page)

    remaining = ImportGroups.member_count(group.id)

    cond do
      remaining == 0 ->
        0

      remaining < remaining_before ->
        drain(group, remaining, page)

      # No progress: every member of that page failed to link, so another pass
      # would fetch the same rows and fail identically. Stop and leave the group
      # `accepted` so a later run can retry it, rather than spinning.
      true ->
        remaining
    end
  end

  # `safe_ingest/2`'s rescue only covers an Elixir-level exception raised
  # before any DB write lands, which is the dominant failure class: the
  # connection stays healthy, the page's transaction commits, and one bad
  # member costs only itself. A genuine database error (a real constraint
  # violation) is different — Postgres marks the *whole* transaction aborted
  # regardless of that rescue, so `Repo.transaction/1` comes back
  # `{:error, :rollback}` and every member in the page is lost, including ones
  # that had already linked successfully earlier in the same page.
  #
  # So the result is inspected: on a clean commit the page is done. On a
  # rollback, the page is replayed one member at a time, each in its own
  # transaction, so a poisoned member costs only itself and its page-mates
  # still commit. The fast path stays per-page deliberately — per-member
  # transactions on SQLite mean one global write-lock acquisition per file, so
  # the slow path is only paid on a page that actually failed.
  defp commit_page(group, page) do
    members = ImportGroups.members(group.id, limit: page)

    case Repo.transaction(fn -> Enum.each(members, &safe_ingest(&1, group)) end) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("An import group page failed to commit, replaying it per member",
          import_group_id: group.id,
          members: length(members),
          reason: inspect(reason)
        )

        Enum.each(members, fn member ->
          Repo.transaction(fn -> safe_ingest(member, group) end)
        end)

        :ok
    end
  end

  # One member's exception must not roll back the page's whole transaction:
  # without this, a single bad member discards every link that already
  # succeeded in the same page, and the log carries no member-level detail to
  # act on.
  defp safe_ingest(member, group) do
    ingest_member(member, group)
  rescue
    error ->
      Logger.error("Ingesting a group member failed, leaving it unresolved",
        import_group_id: group.id,
        media_file_id: member.media_file.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :error
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
