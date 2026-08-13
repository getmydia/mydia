defmodule Mydia.Streaming.AudioPreferences do
  @moduledoc """
  Reads and writes the per-show audio language a viewer chose.

  The strongest of the three preference levels
  `Mydia.Streaming.AudioTrackSelector.resolve_preferences/1` folds together:
  a language someone picked for this show outranks the preference their device
  carries, which outranks the operator's `streaming.audio_language`.

  Every function takes a `user_id` explicitly rather than reading a process
  dictionary or a scope: these are called from a GraphQL resolver, a
  controller and a GenServer, and threading the id keeps the "whose
  preference" question answerable at every call site.
  """

  import Ecto.Query

  alias Mydia.Repo
  alias Mydia.Streaming.AudioLanguagePreference

  @doc """
  The language this viewer chose for this item, or `nil` if they never chose.
  """
  @spec get(binary() | nil, binary() | nil) :: String.t() | nil
  def get(nil, _media_item_id), do: nil
  def get(_user_id, nil), do: nil

  def get(user_id, media_item_id) do
    AudioLanguagePreference
    |> where([p], p.user_id == ^user_id and p.media_item_id == ^media_item_id)
    |> select([p], p.language)
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
  @spec put(binary(), binary(), String.t()) ::
          {:ok, AudioLanguagePreference.t()} | {:error, Ecto.Changeset.t()}
  def put(user_id, media_item_id, language) do
    %AudioLanguagePreference{user_id: user_id, media_item_id: media_item_id}
    |> AudioLanguagePreference.changeset(%{language: language})
    |> Repo.insert(
      on_conflict: {:replace, [:language, :updated_at]},
      conflict_target: [:user_id, :media_item_id]
    )
  end

  @doc """
  Forgets this viewer's choice for this item, returning them to the device and
  operator defaults. Succeeds whether or not a preference existed.
  """
  @spec delete(binary(), binary()) :: :ok
  def delete(user_id, media_item_id) do
    AudioLanguagePreference
    |> where([p], p.user_id == ^user_id and p.media_item_id == ^media_item_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  The language this viewer chose for the item a media file belongs to, as a
  list ready for `AudioTrackSelector.resolve_preferences/1`.

  Returns `[]` rather than `nil` for "no preference", because an empty list is
  how that function spells "this level has no opinion, defer to the next".
  """
  @spec for_media_file(binary() | nil, struct() | nil) :: [String.t()]
  def for_media_file(nil, _media_file), do: []
  def for_media_file(_user_id, nil), do: []

  def for_media_file(user_id, media_file) do
    case get(user_id, media_item_id_of(media_file)) do
      nil -> []
      language -> [language]
    end
  end

  @doc """
  The media item a file belongs to.

  A TV media_file carries a null `media_item_id` and reaches its show only
  through the episode, so reading `media_item_id` alone returns nil for every
  episode and silently disables this feature for the entire TV library. Both
  shapes are handled, movie first.
  """
  @spec media_item_id_of(struct() | nil) :: binary() | nil
  def media_item_id_of(%{media_item_id: id}) when is_binary(id), do: id
  def media_item_id_of(%{episode: %{media_item_id: id}}) when is_binary(id), do: id
  def media_item_id_of(_), do: nil
end
