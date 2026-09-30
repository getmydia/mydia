defmodule Mydia.Plugins.PageContext do
  @moduledoc """
  Helpers shared by the page host functions that run for a signed-in user
  (`Mydia.Plugins.PageActions` and the page read side): resolving the acting
  user from the invocation context and marshalling WIT `option<T>` values.
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Plugins.Error

  @doc """
  The user a page invocation acts for. Only `on-http` invocations carry one;
  any other handler is refused.
  """
  @spec page_user(map()) :: {:ok, User.t()} | {:error, Error.t()}
  def page_user(%{handler: :on_http, acting_user_id: user_id}) when is_binary(user_id) do
    case Accounts.get_user_by_id(user_id) do
      %User{} = user -> {:ok, user}
      nil -> {:error, Error.new(:capability_denied, "unknown user")}
    end
  end

  def page_user(_ctx),
    do: {:error, Error.new(:capability_denied, "page access requires an interactive session")}

  @doc "Reads `key` from a WIT record, unwrapping `{:some, v}` and `:none`."
  @spec opt(map(), atom()) :: term()
  def opt(map, key) do
    case Map.get(map, key) do
      {:some, v} -> v
      :none -> nil
      v -> v
    end
  end

  @doc "Wraps a value as a WIT `option<T>`."
  @spec to_option(term()) :: :none | {:some, term()}
  def to_option(nil), do: :none
  def to_option(value), do: {:some, value}

  @doc "ISO 8601 text for a datetime, nil for nil."
  @spec iso(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def iso(nil), do: nil
  def iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
