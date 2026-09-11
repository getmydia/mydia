defmodule MydiaWeb.LibrarySchema.Middleware.Authorize do
  @moduledoc """
  Rejects a Library API field the caller's principal may not use.

  The schema's `middleware/3` reads each root field's `action` metadata at
  compile time and installs this middleware with that action as its config, so a
  field that declares no action gets no middleware here and is instead refused by
  `middleware/3` itself. Both halves fail closed.

  The error carries `extensions.code = "FORBIDDEN"` so a client can branch on a
  code rather than on message text.
  """

  @behaviour Absinthe.Middleware

  alias Mydia.LibraryApi.Policy

  @impl Absinthe.Middleware
  def call(resolution, action) do
    case Policy.permit?(resolution.context[:principal], action) do
      true ->
        resolution

      false ->
        Absinthe.Resolution.put_result(
          resolution,
          {:error, %{message: "forbidden", extensions: %{code: "FORBIDDEN"}}}
        )
    end
  end
end
