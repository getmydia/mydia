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

  require Logger

  alias Mydia.Metadata.LanguageCode
  alias Mydia.Repo
  alias Mydia.Streaming.AudioPreferences
  alias Mydia.Streaming.SubtitleLanguagePreference
  alias Mydia.Subtitles.Extractor

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

  @doc """
  The subtitle descriptor in effect for this viewer and this file, or `nil`
  when nothing should be selected automatically.

  Two levels, strongest first:

    1. The row this viewer stored for the item, whether a track or an
       explicit off.
    2. The first `streaming.subtitle_language` entry the file actually
       carries a track for.

  Returns a descriptor, never a track id: ids are file-specific and mean
  nothing on the next episode. Matching the descriptor to a track is the
  player's job, because in direct play the list on screen is mpv's and the
  server has never seen it.

  `nil` for an anonymous viewer even when the operator has a default. Without
  a user there is no row to store an override against, so a subtitle selected
  here could never be turned off for that show.
  """
  @spec resolve(binary() | nil, struct() | nil) :: map() | nil
  def resolve(nil, _media_file), do: nil
  def resolve(_user_id, nil), do: nil

  def resolve(user_id, media_file) do
    case get(user_id, media_item_id_of(media_file)) do
      %SubtitleLanguagePreference{mode: :off} ->
        %{mode: :off}

      %SubtitleLanguagePreference{mode: :track} = stored ->
        %{
          mode: :track,
          language: stored.language,
          forced: stored.forced,
          hearing_impaired: stored.hearing_impaired,
          track_title: stored.track_title
        }

      nil ->
        operator_default(media_file)
    end
  end

  # The operator names languages, not tracks, so this narrows to one the file
  # can actually satisfy. Offering a language the file does not carry would
  # send the player hunting for a track that cannot exist.
  defp operator_default(media_file) do
    wanted = Mydia.Settings.get_config([:streaming, :subtitle_language], [])
    available = Extractor.list_subtitle_tracks(media_file)

    Enum.find_value(wanted, fn language ->
      if Enum.any?(available, &LanguageCode.matches?(&1.language, language)) do
        %{
          mode: :track,
          language: language,
          forced: false,
          hearing_impaired: false,
          track_title: nil
        }
      end
    end)
  rescue
    # A file whose stream capture has not run, or whose row is malformed,
    # costs this playback its automatic subtitle and nothing else. Only the
    # errors such a file can actually produce: the descriptor's own map is
    # built from literals, so a bug there must still surface.
    error in [Ecto.Query.CastError, BadMapError, KeyError] ->
      Logger.debug("Could not resolve the operator subtitle default: #{inspect(error)}")
      nil
  end
end
