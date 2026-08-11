defmodule Mydia.WatchSync.Provider do
  @moduledoc """
  Behaviour every watch-state sync provider implements.

  Deliberately provider-agnostic. Plex is the first implementation; Jellyfin,
  Trakt, and plugins are expected to follow without changing the engine.
  """

  @type instance :: map()
  @type user_scope :: %{user_id: binary(), access_token: String.t() | nil}
  @type change :: %{watched: boolean(), position_seconds: integer() | nil}

  @type mapping :: %{
          remote_id: String.t(),
          external_ids: map(),
          season_number: integer() | nil,
          episode_number: integer() | nil,
          type: :movie | :episode
        }

  @type remote_state :: %{
          remote_id: String.t(),
          watched: boolean(),
          position_seconds: integer() | nil,
          at: DateTime.t() | nil
        }

  @doc "Enumerates remote items so they can be matched to local media."
  @callback refresh_mappings(instance(), keyword()) ::
              {:ok, [mapping()]} | {:error, term()}

  @doc """
  Remote watch state changed since `since`.

  `since` is `nil` on a first sync, which means "everything".
  """
  @callback list_changes(instance(), user_scope(), DateTime.t() | nil) ::
              {:ok, [remote_state()]} | {:error, term()}

  @doc "Applies one resolved change to the remote side."
  @callback apply_change(instance(), user_scope(), String.t(), change()) ::
              :ok | {:error, term()}
end
