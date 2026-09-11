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
end
