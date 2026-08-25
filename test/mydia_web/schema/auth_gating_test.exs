defmodule MydiaWeb.Schema.AuthGatingTest do
  @moduledoc """
  Guards the fail-closed authorization posture of the GraphQL root types.

  Authorization used to be opt-in per resolver, which left every browse and
  download field readable by anyone who could reach the endpoint. The structural
  test below is the one that matters over time: it fails when a new root field is
  added without gating, rather than waiting for someone to notice the hole.
  """
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias MydiaWeb.Schema
  alias MydiaWeb.Schema.Middleware.RequireAuth

  @movies_query "{ movies(first: 1) { edges { node { id } } } }"

  # Kept deliberately in step with the allowlist in MydiaWeb.Schema. Adding a
  # field here is a security decision and should be visible in review.
  @public_fields [
    :login,
    :refresh_media_token,
    :refresh_access_token,
    :server_compatibility
  ]
  @introspection_fields [:__schema, :__type, :__typename]

  describe "root field gating" do
    test "every root field requires authentication unless explicitly public" do
      ungated =
        for root <- [:query, :mutation, :subscription],
            type = Absinthe.Schema.lookup_type(Schema, root),
            {identifier, field} <- type.fields,
            identifier not in @public_fields,
            identifier not in @introspection_fields,
            not gated?(field),
            do: "#{root}.#{identifier}"

      assert ungated == [],
             "these root fields are reachable without authentication: #{inspect(ungated)}"
    end

    test "the public allowlist really is reachable without a user" do
      for root <- [:query, :mutation],
          type = Absinthe.Schema.lookup_type(Schema, root),
          {identifier, field} <- type.fields,
          identifier in @public_fields do
        refute gated?(field), "#{identifier} must stay reachable for unauthenticated clients"
      end
    end
  end

  describe "browse queries" do
    test "are denied without an authenticated user" do
      assert {:ok, %{errors: errors}} = Absinthe.run(@movies_query, Schema, context: %{})
      assert Enum.any?(errors, &(&1.message =~ "Authentication required"))
    end

    test "are denied when the context carries a nil user" do
      assert {:ok, %{errors: errors}} =
               Absinthe.run(@movies_query, Schema, context: %{current_user: nil})

      assert Enum.any?(errors, &(&1.message =~ "Authentication required"))
    end

    test "succeed for an authenticated user" do
      user = create_user()

      assert {:ok, %{data: %{"movies" => %{"edges" => edges}}}} =
               Absinthe.run(@movies_query, Schema,
                 context: %{current_user: user, current_scope: Scope.for_user(user)}
               )

      assert is_list(edges)
    end
  end

  defp gated?(field) do
    Enum.any?(field.middleware, fn
      RequireAuth -> true
      {RequireAuth, _} -> true
      _ -> false
    end)
  end

  defp create_user do
    {:ok, user} =
      Accounts.create_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        username: "user#{System.unique_integer([:positive])}",
        password: "password123",
        role: "user"
      })

    user
  end
end
