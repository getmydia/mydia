defmodule Mydia.Streaming.SubtitlePreferences do
  @moduledoc """
  Reads and writes the per-show subtitle a viewer chose.

  The strongest of the two preference levels the player folds together: a
  choice someone made for this show outranks the operator's
  `streaming.subtitle_language`. The fold itself is `resolve/2`.

  Every function takes a `user_id` explicitly rather than reading a process
  dictionary or a scope, matching `Mydia.Streaming.AudioPreferences`: these
  are called from a GraphQL resolver and from tests, and threading the id
  keeps the "whose preference" question answerable at every call site.
  """

  import Ecto.Query

  alias Mydia.Repo
  alias Mydia.Streaming.AudioPreferences
  alias Mydia.Streaming.SubtitleLanguagePreference

  @doc """
  The choice this viewer made for this item, or `nil` if they never chose.
  """
  @spec get(binary() | nil, binary() | nil) :: SubtitleLanguagePreference.t() | nil
  def get(nil, _media_item_id), do: nil
  def get(_user_id, nil), do: nil

  def get(user_id, media_item_id) do
    SubtitleLanguagePreference
    |> where([p], p.user_id == ^user_id and p.media_item_id == ^media_item_id)
    |> Repo.one()
  rescue
    # A malformed id (a client sending something that is not a UUID) is a
    # missing preference, not a crashed playback.
    Ecto.Query.CastError -> nil
  end

  @doc """
  Records this viewer's choice for this item, replacing any earlier one.

  An upsert rather than a fetch-then-update: the unique index makes the write
  atomic, so two devices choosing at once settle on one row instead of one of
  them failing on a duplicate key.
  """
  @spec put(binary(), binary(), map()) ::
          {:ok, SubtitleLanguagePreference.t()} | {:error, Ecto.Changeset.t()}
  def put(user_id, media_item_id, attrs) do
    %SubtitleLanguagePreference{user_id: user_id, media_item_id: media_item_id}
    |> SubtitleLanguagePreference.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:mode, :language, :forced, :hearing_impaired, :track_title, :updated_at]},
      conflict_target: [:user_id, :media_item_id]
    )
  end

  @doc """
  Forgets this viewer's choice for this item, returning them to the operator
  default. Succeeds whether or not a preference existed.
  """
  @spec delete(binary(), binary()) :: :ok
  def delete(user_id, media_item_id) do
    SubtitleLanguagePreference
    |> where([p], p.user_id == ^user_id and p.media_item_id == ^media_item_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  The media item a file belongs to.

  Delegated rather than reimplemented: a TV media_file carries a null
  `media_item_id` and reaches its show only through the episode, and getting
  that wrong silently disables the feature for the entire TV library. One
  implementation, in `Mydia.Streaming.AudioPreferences`.
  """
  @spec media_item_id_of(struct() | map() | nil) :: binary() | nil
  defdelegate media_item_id_of(media_file), to: AudioPreferences
end
