defmodule MydiaWeb.AuthHelpers do
  @moduledoc """
  Authentication helpers for tests.
  """

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  @doc """
  Creates a test user in the database and returns the user struct.
  """
  def create_test_user(attrs \\ %{}) do
    default_attrs = %{
      email: "test-#{System.unique_integer([:positive])}@example.com",
      username: "testuser#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Accounts.create_user()

    user
  end

  @doc """
  Creates an admin test user in the database.
  """
  def create_admin_user(attrs \\ %{}) do
    create_test_user(Map.put(attrs, :role, "admin"))
  end

  @doc """
  Logs in a user for controller tests.
  Returns a conn with the user session and Guardian token set.
  """
  def log_in_user(conn, user \\ nil) do
    user = user || create_test_user()
    {:ok, token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: :access)

    conn
    |> init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_session(:user_id, user.id)
  end

  @doc """
  Creates a valid Guardian authentication token for a user.
  Returns {user, token} tuple.
  """
  def create_user_and_token(attrs \\ %{}) do
    user = create_test_user(attrs)
    {:ok, token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: :access)
    {user, token}
  end

  @doc """
  Registers and logs in a user for LiveView tests.
  Returns {conn, user} tuple when called with a conn.
  When used as a setup callback, returns %{conn: conn, user: user}.
  """
  def register_and_log_in_user(conn, attrs \\ %{})

  def register_and_log_in_user(%{conn: conn}, attrs) do
    user = create_test_user(attrs)
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  def register_and_log_in_user(%Plug.Conn{} = conn, attrs) do
    user = create_test_user(attrs)
    conn = log_in_user(conn, user)
    {conn, user}
  end

  @doc """
  Registers and logs in an admin user for LiveView tests.
  Returns {conn, user} tuple when called with a conn.
  When used as a setup callback, returns %{conn: conn, user: user}.
  """
  def register_and_log_in_admin(context_or_conn, attrs \\ %{})

  def register_and_log_in_admin(%{conn: conn}, attrs) do
    user = create_admin_user(attrs)
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  def register_and_log_in_admin(%Plug.Conn{} = conn, attrs) do
    user = create_admin_user(attrs)
    conn = log_in_user(conn, user)
    {conn, user}
  end

  @doc """
  Logs in a user via the session for LiveView tests.
  This is the standard way to authenticate in LiveView tests.
  """
  def log_in_user_session(conn, user) do
    {:ok, token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: :access)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_session(:user_id, user.id)
  end
end
