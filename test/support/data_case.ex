defmodule Mydia.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Mydia.DataCase, async: true`, although
  this option is not recommended for other databases.

  Note: For SQLite databases, async mode is forcibly disabled to prevent
  "Database busy" errors, regardless of the async option setting.
  """

  use ExUnit.CaseTemplate

  using opts do
    # Allow async mode with PostgreSQL, force sync with SQLite to prevent busy errors
    requested_async = Keyword.get(opts, :async, false)

    async_mode =
      case Application.get_env(:mydia, :database_type) do
        :postgres -> requested_async
        _ -> false
      end

    quote do
      use ExUnit.Case, async: unquote(async_mode)

      alias Mydia.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Mydia.DataCase
      import Mydia.Factory
      import Mydia.ConfigHelpers
    end
  end

  setup tags do
    Mydia.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
