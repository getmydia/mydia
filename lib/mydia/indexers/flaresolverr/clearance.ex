defmodule Mydia.Indexers.FlareSolverr.Clearance do
  @moduledoc """
  Cookies FlareSolverr's browser earned on one host, and the user-agent it
  earned them with. Cloudflare binds `cf_clearance` to that user-agent, so the
  two are only ever sent together.
  """

  @enforce_keys [:key, :cookies, :expires_at]
  defstruct [:key, :user_agent, :expires_at, cookies: []]

  @type t :: %__MODULE__{
          key: String.t(),
          cookies: [{String.t(), String.t()}],
          user_agent: String.t() | nil,
          expires_at: integer()
        }
end
