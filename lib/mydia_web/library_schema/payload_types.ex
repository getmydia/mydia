defmodule MydiaWeb.LibrarySchema.PayloadTypes do
  @moduledoc """
  Mutation payloads and the user errors they carry.

  An expected failure (the title is already in the library, the relay is down, an
  id names nothing) comes back in `userErrors` with the payload's main field
  null, so a client branches on `code` without parsing messages. Top-level
  GraphQL errors stay reserved for authorization and for bugs.
  """

  use Absinthe.Schema.Notation

  @desc "Why a mutation could not do what it was asked"
  enum :user_error_code do
    value(:already_in_library, description: "The title is already in the library")
    value(:not_found, description: "An id names nothing")
    value(:invalid_input, description: "The arguments cannot be satisfied")
    value(:metadata_unavailable, description: "The metadata relay could not provide the title")
    value(:client_unavailable, description: "A download client could not do what was asked")
  end

  @desc "An expected failure, tied to the argument that caused it when there is one"
  object :user_error do
    field :field, list_of(non_null(:string)), description: "Path to the argument, as sent"
    field :code, non_null(:user_error_code)
    field :message, non_null(:string)
  end

  @desc "The media item a mutation changed"
  object :media_item_payload do
    field :media_item, :media_item
    field :user_errors, non_null(list_of(non_null(:user_error)))
  end
end
