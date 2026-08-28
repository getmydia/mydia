defmodule Mydia.Jobs.ExtraClassification do
  @moduledoc """
  Recurring worker that decides which of a movie's files are versions of the
  movie and which are bonus content, using the duration
  `Mydia.Jobs.FileAnalysis` wrote.

  Selection is by row state, so the worker is idempotent: each tick takes a
  bounded batch of movies with at least one file needing a look and classifies
  each movie's files as a set. Batching by movie rather than by file is
  required by the last-version-survives invariant in
  `Mydia.Library.ExtraClassifier`, which can only be evaluated with a movie's
  whole file set in hand.

  Existing libraries need no backfill. Every row has `extra_checked_at IS NULL`
  right after the migration, so they are picked up by the normal ticks. The
  second selection tier re-checks the oldest-stamped movies with whatever
  capacity is left, so a movie that gains a TMDB runtime later reclassifies on
  its own.

  ## Configuration

      config :mydia, :extra_classification_batch_size, 50
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.Library.ExtraClassifier
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @default_batch_size 50

  @spec perform(Oban.Job.t()) :: :ok
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    batch_size =
      Application.get_env(:mydia, :extra_classification_batch_size, @default_batch_size)

    unchecked = fetch_unchecked_item_ids(batch_size)
    aged = fetch_aged_item_ids(max(batch_size - length(unchecked), 0), unchecked)

    case unchecked ++ aged do
      [] ->
        :ok

      item_ids ->
        Logger.debug("ExtraClassification processing batch", count: length(item_ids))
        Enum.each(item_ids, &classify_item/1)
        :ok
    end
  end

  # Movies holding at least one classifiable file.
  #
  # The join on type is what keeps this a movies-only feature: media_item_id is
  # also set on TV files that have a show but no episode yet, and on galactica
  # that is 123 of the 477 rows with a non-null media_item_id.
  #
  # `is_nil(extra_source) or extra_source == :duration` is a positive match on
  # purpose. `extra_source != :operator` would drop every NULL row under SQL
  # three-valued logic, which is every row on a freshly migrated database, and
  # the worker would silently never do anything. It also encodes layer
  # priority: folder and filename decisions from the scanner outrank duration,
  # so this pass never revisits them.
  defp base_item_query do
    from(mf in MediaFile,
      join: mi in MediaItem,
      on: mi.id == mf.media_item_id,
      where:
        mi.type == "movie" and is_nil(mf.trashed_at) and not is_nil(mf.analyzed_at) and
          (is_nil(mf.extra_source) or mf.extra_source == :duration),
      select: mf.media_item_id
    )
  end

  defp fetch_unchecked_item_ids(0), do: []

  defp fetch_unchecked_item_ids(limit) do
    base_item_query()
    |> where([mf], is_nil(mf.extra_checked_at))
    |> distinct(true)
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_aged_item_ids(0, _exclude_ids), do: []

  defp fetch_aged_item_ids(limit, exclude_ids) do
    base_item_query()
    |> where([mf], not is_nil(mf.extra_checked_at))
    |> where([mf], mf.media_item_id not in ^exclude_ids)
    |> group_by([mf], mf.media_item_id)
    |> order_by([mf], asc: min(mf.extra_checked_at))
    |> limit(^limit)
    |> Repo.all()
  end

  defp classify_item(item_id) do
    item = Repo.get(MediaItem, item_id)

    files =
      MediaFile.active()
      |> where([mf], mf.media_item_id == ^item_id)
      |> Repo.all()

    {eligible, protected} = Enum.split_with(files, &eligible?/1)

    # Protected rows still count toward the invariant: a movie whose only
    # version was promoted by an operator must not have a second file forced
    # into the version slot behind their back.
    reference_files = eligible ++ Enum.filter(protected, &is_nil(&1.extra_kind))

    decisions = ExtraClassifier.classify(runtime(item), reference_files)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(eligible, fn file ->
      case Map.fetch(decisions, file.id) do
        {:ok, :extra} ->
          write(file, %{extra_kind: :other, extra_source: :duration}, now)

        {:ok, :version} ->
          write(file, %{extra_kind: nil, extra_source: nil}, now)

        # analyzed_at is set but there is no usable duration. Stamp it so the
        # worker does not reselect the movie on every tick.
        :error ->
          write(file, %{}, now)
      end
    end)
  end

  defp eligible?(file) do
    not is_nil(file.analyzed_at) and
      (is_nil(file.extra_source) or file.extra_source == :duration)
  end

  defp write(file, attrs, now) do
    file
    |> MediaFile.changeset(Map.put(attrs, :extra_checked_at, now))
    |> Repo.update()
  end

  defp runtime(%MediaItem{metadata: %{runtime: runtime}}) when is_integer(runtime), do: runtime
  defp runtime(_item), do: nil
end
