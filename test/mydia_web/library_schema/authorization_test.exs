defmodule MydiaWeb.LibrarySchema.AuthorizationTest do
  @moduledoc """
  Every root field must declare an `action`, and `Authorize` must fail closed for
  anything that does not. The first test also pins the mechanism the design rests
  on: Absinthe exposes DSL `meta` through `Absinthe.Type.meta/2`.
  """
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Policy
  alias Mydia.LibraryApi.Principal

  @admin %Principal{role: "admin", source: :api_key}
  @user %Principal{role: "user", source: :api_key}

  describe "field action metadata" do
    test "Absinthe.Type.meta/2 reads a field's DSL-declared action" do
      field =
        Absinthe.Schema.lookup_type(MydiaWeb.LibrarySchema, :library_queries).fields[
          :quality_profiles
        ]

      assert Absinthe.Type.meta(field, :action) == :read_library
    end

    test "every root field except introspection declares an action" do
      fields = Absinthe.Schema.lookup_type(MydiaWeb.LibrarySchema, :library_queries).fields

      missing =
        fields
        |> Enum.reject(fn {name, field} ->
          name in [:__schema, :__type, :__typename] or
            not is_nil(Absinthe.Type.meta(field, :action))
        end)
        |> Enum.map(&elem(&1, 0))

      assert missing == [], "root fields missing an action: #{inspect(missing)}"
    end
  end

  describe "Policy.permit?/2" do
    test "an admin principal is permitted" do
      assert Policy.permit?(@admin, :read_library)
      assert Policy.permit?(@admin, :read_downloads)
    end

    test "a non-admin principal is denied every action" do
      refute Policy.permit?(@user, :read_library)
      refute Policy.permit?(@user, :read_downloads)
    end

    test "a nil principal is denied" do
      refute Policy.permit?(@admin |> Map.put(:role, nil), :read_library)
    end
  end

  describe "the Authorize middleware" do
    @profiles_query "{ qualityProfiles { id name } }"

    test "denies a field when the principal lacks the action" do
      assert {:ok, %{errors: errors}} =
               Absinthe.run(@profiles_query, MydiaWeb.LibrarySchema, context: %{principal: @user})

      assert Enum.any?(errors, &(&1.message =~ "forbidden"))
      assert Enum.any?(errors, &(&1.extensions[:code] == "FORBIDDEN"))
    end

    test "allows a field when the principal holds the action" do
      assert {:ok, %{data: %{"qualityProfiles" => profiles}}} =
               Absinthe.run(@profiles_query, MydiaWeb.LibrarySchema,
                 context: %{principal: @admin}
               )

      assert is_list(profiles)
    end

    test "denies when no principal is present at all" do
      assert {:ok, %{errors: errors}} =
               Absinthe.run(@profiles_query, MydiaWeb.LibrarySchema, context: %{})

      assert Enum.any?(errors, &(&1.extensions[:code] == "FORBIDDEN"))
    end
  end
end
