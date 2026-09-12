defmodule MydiaWeb.LibrarySchema do
  @moduledoc """
  GraphQL schema for the Library API.

  BETA: breaking changes are possible and are announced in release notes.

  Separate from `MydiaWeb.Schema` on purpose. The player schema is a shared
  contract with the Rust server and the Flutter client, gated by
  `server/crates/api/tests/sdl_parity.rs`; this schema is neither, so the two
  must not share types or evolve together.
  """

  use Absinthe.Schema

  import_types(Absinthe.Type.Custom)
  import_types(MydiaWeb.LibrarySchema.EnumTypes)
  import_types(MydiaWeb.LibrarySchema.ReferenceTypes)
  import_types(MydiaWeb.LibrarySchema.QueryTypes)
  import_types(MydiaWeb.LibrarySchema.MediaTypes)
  import_types(MydiaWeb.LibrarySchema.DownloadTypes)
  import_types(MydiaWeb.LibrarySchema.PayloadTypes)
  import_types(MydiaWeb.LibrarySchema.MutationTypes)
  import_types(MydiaWeb.LibrarySchema.EventTypes)

  @introspection_fields [:__schema, :__type, :__typename]

  @doc """
  Installs `{Authorize, action}` on every root field that declares an `action`.

  A root field without one is an error rather than a default: authorization has
  to fail closed, and a field nobody marked is a field nobody decided about.
  """
  def middleware(middleware, field, %{identifier: root}) when root in [:query, :mutation] do
    if field.identifier in @introspection_fields do
      middleware
    else
      case Absinthe.Type.meta(field, :action) do
        nil ->
          raise ArgumentError,
                "Library API root field #{inspect(field.identifier)} declares no action. " <>
                  "Add `meta action: :read_library` (or another action in " <>
                  "#{inspect(Mydia.LibraryApi.Policy.actions())}) to it."

        action ->
          [{MydiaWeb.LibrarySchema.Middleware.Authorize, action} | middleware]
      end
    end
  end

  def middleware(middleware, _field, _object), do: middleware

  query do
    import_fields(:library_queries)
  end

  mutation do
    import_fields(:library_mutations)
  end
end
