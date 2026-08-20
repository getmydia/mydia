defmodule Mydia.RemoteAccessHelpers do
  @moduledoc """
  Seeds the `Mydia.RemoteAccess.enabled?/0` cache directly.

  The flag lives in `:persistent_term`, which the Ecto sandbox does not roll
  back. Any test that reads or writes it must be `async: false` and must reset
  it, or a value set by one test decides the outcome of another.
  """

  @enabled_key {Mydia.RemoteAccess, :enabled}

  @doc "Forces `RemoteAccess.enabled?/0` to return the given value."
  @spec set_remote_access(boolean()) :: :ok
  def set_remote_access(enabled) when is_boolean(enabled) do
    :persistent_term.put(@enabled_key, enabled)
  end

  @doc "Clears the cached flag so the next read falls back to the database."
  @spec reset_remote_access() :: :ok
  def reset_remote_access do
    :persistent_term.erase(@enabled_key)
    :ok
  end
end
