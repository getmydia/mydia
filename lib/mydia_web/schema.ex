defmodule MydiaWeb.Schema do
  @moduledoc """
  GraphQL schema for the Mydia player API.

  Provides a unified GraphQL interface for the Flutter player client to:
  - Browse libraries (movies, TV shows)
  - Get playback information
  - Track playback progress
  - Discover content (continue watching, recently added, up next)

  This schema works with the existing data model:
  - MediaItem (movies and TV shows)
  - Episode (TV episodes)
  - MediaFile (video files)
  - Progress (playback tracking)
  """

  use Absinthe.Schema

  import_types(Absinthe.Type.Custom)
  import_types(MydiaWeb.Schema.EnumTypes)
  import_types(MydiaWeb.Schema.CommonTypes)
  import_types(MydiaWeb.Schema.MediaTypes)
  import_types(MydiaWeb.Schema.QueryTypes)
  import_types(MydiaWeb.Schema.MutationTypes)
  import_types(MydiaWeb.Schema.SubscriptionTypes)

  query do
    import_fields(:browse_queries)
    import_fields(:discovery_queries)
    import_fields(:search_queries)
    import_fields(:api_key_queries)
    import_fields(:device_queries)
    import_fields(:remote_access_queries)
    import_fields(:streaming_queries)
    import_fields(:collection_queries)
  end

  mutation do
    import_fields(:playback_mutations)
    import_fields(:remote_access_mutations)
    import_fields(:api_key_mutations)
    import_fields(:auth_mutations)
    import_fields(:device_mutations)
    import_fields(:streaming_mutations)
    import_fields(:download_mutations)
  end

  subscription do
    import_fields(:playback_subscriptions)
    import_fields(:device_subscriptions)
  end

  # Root fields that must stay reachable without an authenticated user: logging
  # in, and trading an existing credential for a fresh one. Everything else is
  # denied by default. Introspection is left open so GraphiQL keeps working; it
  # exposes the schema shape only, never data.
  @public_fields [:login, :refresh_media_token, :refresh_access_token]
  @introspection_fields [:__schema, :__type, :__typename]

  @doc """
  Applies fail-closed authentication to every root field.

  Authorization used to be opt-in inside each resolver, so any resolver that
  omitted its own `current_user` check was readable by anyone who could reach the
  endpoint. This inverts the default: a root field requires an authenticated user
  unless it is explicitly listed in `@public_fields`.
  """
  def middleware(middleware, field, %{identifier: object})
      when object in [:query, :mutation, :subscription] do
    if field.identifier in @public_fields or field.identifier in @introspection_fields do
      middleware
    else
      [MydiaWeb.Schema.Middleware.RequireAuth | middleware]
    end
  end

  def middleware(middleware, _field, _object), do: middleware
end
