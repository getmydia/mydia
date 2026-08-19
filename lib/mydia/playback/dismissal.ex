defmodule Mydia.Playback.Dismissal do
  @moduledoc """
  One viewer taking one title off the Continue Watching rail.

  Written when someone picks "Remove from Continue Watching" on a card, and
  read back by `Mydia.Playback.OnDeck` on every rail build.

  Scoped to the media item, so for a series this is the show rather than the
  episode. `OnDeck` emits at most one card per show, and dismissing only the
  episode behind that card would hand the show straight back with the next
  one.

  A dismissal hides; it does not unwatch. The `Mydia.Playback.Progress` row
  survives untouched, so the resume point is still there when the viewer comes
  back to the title from a detail page. That separation is the whole reason
  this table exists rather than the feature reusing `delete_progress/3`, which
  would both discard the resume point and emit a `playback.unwatched` event
  that `Mydia.WatchSync` pushes out to Plex and Jellyfin.

  `dismissed_at` is a timestamp rather than a boolean because the hide expires
  on its own: `OnDeck` shows the title again as soon as its most recent watch
  is newer than this stamp, so playing the title is all it takes to undo, and
  no job ever has to sweep this table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          dismissed_at: DateTime.t(),
          user_id: binary(),
          media_item_id: binary(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "continue_watching_dismissals" do
    field :dismissed_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User
    belongs_to :media_item, Mydia.Media.MediaItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a dismissal.

  `user_id` and `media_item_id` are set programmatically by the context rather
  than cast, so a client cannot hide a title on another account's rail.
  """
  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:dismissed_at])
    |> validate_required([:dismissed_at])
    |> unique_constraint([:user_id, :media_item_id])
    # Backstop only. SQLite reports a foreign key violation with no constraint
    # name, so Ecto cannot match these and raises instead; the context checks
    # the media item exists up front for that reason. These still earn their
    # place on Postgres, where they turn the insert-after-delete race into a
    # changeset error rather than a five hundred.
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:user_id)
  end
end
