defmodule Mydia.Indexers.Cardigann.SessionManager do
  @moduledoc """
  Gives searches and health checks a logged-in session for a Cardigann definition.

  Loads the stored session, logs in when there is none, and when a search comes back
  logged out invalidates it, logs in once and retries once. A login that needs a
  person (captcha, one-time code) moves the definition to `needs_login`, which
  searches then skip until someone logs in from the admin page.
  """

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.{LoggedOut, Login}
  alias Mydia.Indexers.Cardigann.Login.Session
  alias Mydia.Indexers.{CardigannAuth, CardigannDefinition}
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Repo

  @topic "cardigann:health"
  @pubsub Mydia.PubSub

  def topic, do: @topic

  @spec user_config(Parsed.t(), CardigannDefinition.t()) :: {:ok, map()} | {:error, Error.t()}
  def user_config(%Parsed{login: nil}, _definition), do: {:ok, %{}}

  def user_config(_parsed, %CardigannDefinition{health_status: "needs_login", name: name}),
    do: {:error, needs_login_error(name)}

  def user_config(%Parsed{} = parsed, %CardigannDefinition{} = definition) do
    case CardigannAuth.get_stored_session(definition.id) do
      {:ok, %{cookies: cookies}} -> {:ok, %{cookies: cookies}}
      {:error, _} -> login(parsed, definition)
    end
  end

  @spec with_session(Parsed.t(), CardigannDefinition.t(), (map() -> any())) :: any()
  def with_session(%Parsed{} = parsed, %CardigannDefinition{} = definition, search) do
    with {:ok, user_config} <- user_config(parsed, definition) do
      result = search.(user_config)

      case LoggedOut.check(parsed, unwrap(result), cookies?(user_config)) do
        :ok -> result
        :logged_out -> relogin_and_retry(parsed, definition, search)
      end
    end
  end

  @spec store(CardigannDefinition.t(), Session.t()) :: :ok
  def store(%CardigannDefinition{} = definition, %Session{} = session) do
    case CardigannAuth.store_session(definition.id, session.cookies, session.expires_at) do
      {:ok, _} ->
        if definition.health_status == "needs_login", do: set_status(definition, "healthy")

      {:error, _changeset} ->
        Logger.warning("Cardigann #{definition.indexer_id}: could not save the login session")
    end

    :ok
  end

  defp relogin_and_retry(parsed, definition, search) do
    Logger.info("Cardigann #{definition.indexer_id}: session rejected, logging in again")
    CardigannAuth.invalidate_session(definition.id)

    with {:ok, user_config} <- login(parsed, definition) do
      result = search.(user_config)

      case LoggedOut.check(parsed, unwrap(result), cookies?(user_config)) do
        :ok ->
          result

        :logged_out ->
          {:error,
           Error.authentication_failed(
             "Logged in, but #{definition.name} still treats searches as logged out"
           )}
      end
    end
  end

  defp login(parsed, definition) do
    case Login.begin(parsed, definition) do
      {:ok, %Session{} = session} ->
        store(definition, session)
        {:ok, %{cookies: session.cookies}}

      {:needs_input, _challenge} ->
        set_status(definition, "needs_login")
        {:error, needs_login_error(definition.name)}

      {:error, _} = error ->
        error
    end
  end

  defp needs_login_error(name),
    do: Error.login_required("#{name} needs someone to log in from the Indexers page")

  defp set_status(definition, status) do
    attrs = %{
      health_status: status,
      last_health_check_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case definition |> CardigannDefinition.health_check_changeset(attrs) |> Repo.update() do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.warning("Cardigann #{definition.indexer_id}: could not set health status")
    end

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:cardigann_health_changed, definition.id})
  end

  # The search function returns the response alone or with the caller's extra data
  # (the adapter's FlareSolverr marker, the test's user_config).
  defp unwrap({{:ok, _} = ok, _extra}), do: ok
  defp unwrap({{:error, _} = err, _extra}), do: err
  defp unwrap(other), do: other

  defp cookies?(%{cookies: [_ | _]}), do: true
  defp cookies?(_), do: false
end
