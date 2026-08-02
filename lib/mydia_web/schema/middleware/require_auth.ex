defmodule MydiaWeb.Schema.Middleware.RequireAuth do
  @moduledoc """
  Absinthe middleware that rejects a resolution when no user is authenticated.

  `MydiaWeb.Schema.middleware/3` applies this to every root query, mutation and
  subscription field outside a small public allowlist, so authorization fails
  closed. Resolvers may still perform their own `current_user` checks; those now
  act as defence in depth rather than as the only barrier.

  The error message matches the one resolvers already return so clients have a
  single string to detect an expired or missing token.
  """

  @behaviour Absinthe.Middleware

  @impl Absinthe.Middleware
  def call(%{context: %{current_user: user}} = resolution, _config) when not is_nil(user) do
    resolution
  end

  def call(resolution, _config) do
    Absinthe.Resolution.put_result(resolution, {:error, "Authentication required"})
  end
end
