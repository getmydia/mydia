defmodule Mydia.LibraryApi.Principal do
  @moduledoc """
  Who is making a Library API request.

  `source` records how the request authenticated, which is what lets the
  environment key act without a user row while a database key carries the user
  its activity should be attributed to.
  """

  @enforce_keys [:role, :source]
  defstruct [:role, :source, :user, :api_key_id]

  @type t :: %__MODULE__{
          role: String.t() | nil,
          source: :api_key | :env,
          user: Mydia.Accounts.User.t() | nil,
          api_key_id: binary() | nil
        }

  @doc """
  The `actor_type`/`actor_id` options for context functions that record who acted.

  A database key acts as its owner. The environment key has no user behind it, so
  it acts as the system under a fixed name that says where the change came from.
  """
  @spec actor_opts(t()) :: keyword()
  def actor_opts(%__MODULE__{source: :api_key, user: %{id: user_id}}),
    do: [actor_type: :user, actor_id: user_id]

  def actor_opts(%__MODULE__{}), do: [actor_type: :system, actor_id: "library_api_key"]
end
