defmodule Mydia.Indexers.Cardigann.SessionManager do
  @moduledoc """
  Gives searches and health checks a logged-in session for a Cardigann definition.

  Loads the stored session, logs in when there is none, and when a search comes back
  logged out invalidates it, logs in once and retries once. A login that needs a
  person (captcha, one-time code) moves the definition to `needs_login`, which
  searches then skip until someone logs in from the admin page.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

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
      {result, sent?} = run(search, user_config)

      case LoggedOut.check(parsed, unwrap(result), sent?) do
        :ok -> result
        :logged_out -> relogin_and_retry(parsed, definition, search, user_config[:cookies])
      end
    end
  end

  @spec store(CardigannDefinition.t(), Session.t()) :: :ok
  def store(%CardigannDefinition{} = definition, %Session{} = session) do
    case CardigannAuth.store_session(definition.id, session.cookies, session.expires_at) do
      {:ok, _} ->
        clear_needs_login(definition)

      {:error, _changeset} ->
        Logger.warning("Cardigann #{definition.indexer_id}: could not save the login session")
    end

    :ok
  end

  defp relogin_and_retry(parsed, definition, search, rejected) do
    with {:ok, user_config} <- fresh_session(parsed, definition, rejected) do
      {result, sent?} = run(search, user_config)

      case LoggedOut.check(parsed, unwrap(result), sent?) do
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

  # A search running alongside may already have replaced the rejected session.
  # Delete only the rejected cookies, then reuse whatever session is stored, and
  # log in only when there is none.
  defp fresh_session(parsed, definition, rejected) do
    CardigannAuth.invalidate_session(definition.id, rejected || [])

    case CardigannAuth.get_stored_session(definition.id) do
      {:ok, %{cookies: cookies}} ->
        {:ok, %{cookies: cookies}}

      {:error, _} ->
        Logger.info("Cardigann #{definition.indexer_id}: session rejected, logging in again")
        login(parsed, definition)
    end
  end

  # Whether the cookies went out is what the search engine recorded; a search
  # function that bypasses the engine records nothing, so fall back to whether
  # there were cookies to send.
  defp run(search, user_config) do
    LoggedOut.take_session_sent()
    result = search.(user_config)

    sent? =
      case LoggedOut.take_session_sent() do
        nil -> cookies?(user_config)
        sent? -> sent?
      end

    {result, sent?}
  end

  defp login(parsed, definition) do
    case Login.begin(parsed, definition) do
      {:ok, %Session{} = session} ->
        store(definition, session)
        {:ok, %{cookies: session.cookies}}

      {:needs_input, _challenge} ->
        park(definition)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Moves a definition to `needs_login` and returns the `:login_required` error
  searches report. For a login that needs a person; the wasm adapter calls it
  too, so both engines park such a definition the same way.

  A person may log in from the Indexers page while a search is failing. The
  status is written first and the stored session read after, so whichever of
  `park/1` and `store/2` runs last, a stored session never stays parked; when
  one exists it is returned as the search's `user_config`.
  """
  @spec park(CardigannDefinition.t()) :: {:ok, map()} | {:error, Error.t()}
  def park(%CardigannDefinition{} = definition) do
    set_status(definition, "needs_login")

    case CardigannAuth.get_stored_session(definition.id) do
      {:ok, %{cookies: cookies}} ->
        clear_needs_login(definition)
        {:ok, %{cookies: cookies}}

      {:error, _} ->
        {:error, needs_login_error(definition.name)}
    end
  end

  @doc """
  Moves a definition out of `needs_login` once a session is stored. Reads the
  status from the database, not the caller's struct, which may be stale.
  """
  @spec clear_needs_login(CardigannDefinition.t()) :: :ok
  def clear_needs_login(%CardigannDefinition{id: id}) do
    {count, _} =
      from(d in CardigannDefinition, where: d.id == ^id and d.health_status == "needs_login")
      |> Repo.update_all(set: [health_status: "healthy", last_health_check_at: now()])

    if count > 0,
      do: Phoenix.PubSub.broadcast(@pubsub, @topic, {:cardigann_health_changed, id})

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp needs_login_error(name),
    do: Error.login_required("#{name} needs someone to log in from the Indexers page")

  # By id, so a stale struct whose status already reads the target value still
  # writes it.
  defp set_status(definition, status) do
    from(d in CardigannDefinition, where: d.id == ^definition.id)
    |> Repo.update_all(set: [health_status: status, last_health_check_at: now()])

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
