defmodule Mydia.Indexers.CardigannAuth do
  @moduledoc """
  Persists Cardigann login sessions.

  Logging in is `Mydia.Indexers.Cardigann.Login`; `Mydia.Indexers.Cardigann.SessionManager`
  decides when to log in. This module only stores, reads and drops the cookies a
  login produced, one row per definition.

  Session cookies are stored in the database (database security is the
  responsibility of the deployment) and are never logged.
  """

  alias Mydia.Indexers.CardigannSearchSession
  alias Mydia.Repo

  import Ecto.Query

  @type session :: %{
          cookies: [String.t()],
          expires_at: DateTime.t() | nil,
          method: :form
        }

  @doc """
  Retrieves stored session cookies for a definition from the database.

  ## Parameters

  - `cardigann_definition_id` - Database ID of the definition

  ## Returns

  - `{:ok, session}` - Session data with cookies
  - `{:error, :not_found}` - No session found
  - `{:error, :expired}` - Session exists but has expired
  """
  @spec get_stored_session(String.t()) :: {:ok, session()} | {:error, atom()}
  def get_stored_session(cardigann_definition_id) do
    query =
      from s in CardigannSearchSession,
        where: s.cardigann_definition_id == ^cardigann_definition_id

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %CardigannSearchSession{} = session ->
        if CardigannSearchSession.expired?(session) do
          {:error, :expired}
        else
          # session.cookies is now directly a list (not wrapped in a map)
          cookies = session.cookies || []

          {:ok,
           %{
             cookies: cookies,
             expires_at: session.expires_at,
             method: :form
           }}
        end
    end
  end

  @doc """
  Stores session cookies in the database.

  ## Parameters

  - `cardigann_definition_id` - Database ID of the definition
  - `cookies` - List of cookie strings to store
  - `expires_at` - Session expiration time (optional, nil means no expiry).
    Upserts: one row is kept per definition.

  ## Returns

  - `{:ok, session_record}` - Successfully stored session
  - `{:error, changeset}` - Storage failed
  """
  @spec store_session(String.t(), [String.t()], DateTime.t() | nil) ::
          {:ok, CardigannSearchSession.t()} | {:error, Ecto.Changeset.t()}
  def store_session(cardigann_definition_id, cookies, expires_at \\ nil) do
    %CardigannSearchSession{}
    |> CardigannSearchSession.changeset(%{
      cardigann_definition_id: cardigann_definition_id,
      cookies: cookies,
      expires_at: expires_at
    })
    |> Repo.insert(
      on_conflict: {:replace, [:cookies, :expires_at, :updated_at]},
      conflict_target: :cardigann_definition_id,
      returning: true
    )
  end

  @doc """
  Deletes the stored session for a definition, forcing a fresh login.
  """
  @spec invalidate_session(String.t()) :: :ok
  def invalidate_session(cardigann_definition_id) do
    from(s in CardigannSearchSession,
      where: s.cardigann_definition_id == ^cardigann_definition_id
    )
    |> Repo.delete_all()

    :ok
  end
end
