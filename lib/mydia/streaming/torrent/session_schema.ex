defmodule Mydia.Streaming.Torrent.SessionSchema do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "torrent_streaming_sessions" do
    field :release_title, :string
    field :infohash, :string
    field :magnet, :string
    field :file_id, :integer
    field :staging_path, :string
    field :total_bytes, :integer

    field :state, Ecto.Enum,
      values: [
        :initializing,
        :downloading,
        :ready,
        :watching,
        :promoting,
        :completed,
        :failed,
        :cancelled
      ]

    field :started_at, :utc_datetime
    field :last_progress_at, :utc_datetime
    field :download_progress, :float, default: 0.0

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @user_castable_fields [
    :release_title,
    :infohash,
    :magnet,
    :file_id,
    :staging_path,
    :total_bytes,
    :state,
    :started_at,
    :last_progress_at,
    :download_progress
  ]

  @ownership_fields [:media_item_id, :episode_id, :user_id]

  @doc """
  Public changeset.

  Note: `user_id`, `media_item_id`, and `episode_id` are NOT cast from `attrs`;
  they must be supplied programatically via `put_change/3` from the caller
  (see `create_session_record/1` in the context). This avoids horizontal-
  privilege bugs if a future caller passes attrs straight from user input.
  """
  def changeset(session, attrs) do
    {ownership_attrs, user_attrs} = split_ownership_attrs(attrs)

    session
    |> cast(user_attrs, @user_castable_fields)
    |> put_ownership(ownership_attrs)
    |> validate_required([:release_title, :magnet, :state, :started_at, :user_id])
    |> validate_number(:download_progress,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> unique_constraint(:infohash, name: :torrent_streaming_sessions_infohash_index)
  end

  defp split_ownership_attrs(attrs) when is_map(attrs) do
    Enum.reduce(@ownership_fields, {%{}, attrs}, fn field, {ownership, rest} ->
      case Map.pop(rest, field) do
        {nil, rest_after} ->
          # Try the string-key variant as well, since Absinthe sometimes
          # passes attribute maps with string keys.
          case Map.pop(rest_after, Atom.to_string(field)) do
            {nil, rest_final} -> {ownership, rest_final}
            {value, rest_final} -> {Map.put(ownership, field, value), rest_final}
          end

        {value, rest_after} ->
          {Map.put(ownership, field, value), rest_after}
      end
    end)
  end

  defp put_ownership(changeset, ownership_attrs) do
    Enum.reduce(ownership_attrs, changeset, fn {field, value}, cs ->
      put_change(cs, field, value)
    end)
  end
end
