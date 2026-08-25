defmodule Mydia.Jobs.ContentRatingAgeBackfill do
  @moduledoc """
  Derives `media_items.content_rating_age` for rows written before that column
  existed.

  Pure computation over metadata already stored, with no network calls, so it
  finishes in one pass over the library. It cannot help a title that has no
  rating stored at all, which on a default install is every TVDB-sourced show
  until a metadata refresh reaches it.

  Idempotent, and matches nothing once the library is caught up.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [
      period: 3_600,
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.Media.ContentRating
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @spec perform(Oban.Job.t()) :: :ok
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    updated =
      from(m in MediaItem,
        where: is_nil(m.content_rating_age) and not is_nil(m.metadata),
        select: struct(m, [:id, :metadata])
      )
      |> Repo.all()
      |> Enum.reduce(0, fn item, acc ->
        case derive(item) do
          nil -> acc
          age -> acc + set_age(item.id, age)
        end
      end)

    Logger.info("ContentRatingAgeBackfill filled #{updated} media items")

    :ok
  end

  defp derive(%MediaItem{metadata: %{content_rating: rating}}),
    do: ContentRating.min_age(rating)

  defp derive(_item), do: nil

  # update_all rather than a changeset, so the metadata blob is not rewritten
  # and updated_at does not move for a purely derived value.
  defp set_age(id, age) do
    {count, _} =
      Repo.update_all(from(m in MediaItem, where: m.id == ^id),
        set: [content_rating_age: age]
      )

    count
  end
end
