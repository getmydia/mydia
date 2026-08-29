defmodule Mydia.Jobs.ApplyImportGroups do
  @moduledoc """
  Commits accepted import groups.

  Runs on `:default` rather than `:imports`, which has concurrency 1 and is held
  for the duration of a library scan. An accept queued behind a multi-hour run
  would look like the button did nothing.

  Members are fetched in bounded pages, but the worker does not wrap a page in
  a transaction. `FileIngest` performs metadata network requests while linking
  a member, so a worker-owned transaction would hold SQLite's global write lock
  across slow external I/O and make unrelated pages unavailable. The contexts
  called by `FileIngest` own their individual, short database writes, while
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

  `accepted_groups/1` skips a group with no `provider_id`, and separately
  skips one with `provider_type: "local"`: neither has anything for
  `FileIngest` to apply, so every member would fail identically on every
  retry, burning the retry budget on work that can never succeed. A
  provider-less group can still reach `"accepted"` -- `accept/1` does not
  check the band of what it accepts, so a "select all" spanning `:no_match`
  marks one `"accepted"` the same as any other. A `provider_type: "local"`
  group carries a synthetic `provider_id` (`Mydia.ImportGroups.create_local_show/1`
  stamps one so a second call against the same group is refused), which would
  otherwise slip past the first filter and get handed to `FileIngest` with an
  id no provider recognises.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, keys: [:library_path_id], states: :incomplete]

  import Ecto.Query

  require Logger

  alias Mydia.ImportGroups
  alias Mydia.Library.{FileIngest, ImportGroup, MatchCandidate}
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
    # A group with no provider match, or a synthetic local-show provider
    # match, has nothing for FileIngest to apply -- see the moduledoc note
    # above.
    |> where([g], not is_nil(g.provider_id))
    |> where([g], is_nil(g.provider_type) or g.provider_type != "local")
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
  # The page is only a bound on fetched work. It must not become a transaction
  # boundary because ingesting a member includes external metadata requests.
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

  # Do not add an outer transaction here. `safe_ingest/2` reaches metadata
  # providers and can spend seconds waiting on the network after an earlier
  # write. Keeping each member outside a worker-owned transaction lets the
  # lower-level contexts acquire SQLite's write lock only for their actual DB
  # operations, and one failed member does not roll back its page-mates.
  defp commit_page(group, page) do
    group.id
    |> ImportGroups.members(limit: page)
    |> Enum.each(&safe_ingest(&1, group))
  end

  # One member's exception must not stop the rest of the page, and the log must
  # carry enough member-level detail to act on it.
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
    base = MatchCandidate.to_match(candidate)

    match = %{
      base
      | provider_id: candidate.provider_id || group.provider_id,
        provider_type:
          MatchCandidate.known_provider(candidate.provider_type) ||
            MatchCandidate.known_provider(group.provider_type) || :tvdb,
        title: candidate.title || group.suggested_title,
        year: candidate.year || group.suggested_year,
        match_confidence: candidate.confidence || group.min_confidence || 1.0,
        parsed_info: %{
          MatchCandidate.parsed_info(candidate)
          | type: MatchCandidate.media_type_atom(candidate.media_type || group.media_type)
        }
    }

    media_file = Repo.preload(media_file, :library_path)

    FileIngest.ingest(media_file, match, policy: :create_items)
  end

  defp broadcast(library_path_id) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "import_groups:#{library_path_id}",
      {:import_groups_changed, library_path_id}
    )
  end
end
