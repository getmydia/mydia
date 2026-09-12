defmodule MydiaWeb.LibrarySchema.UserErrorTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias MydiaWeb.LibrarySchema.UserError

  test "changeset errors become INVALID_INPUT with a camelCased path and Ecto's placeholders filled" do
    changeset =
      {%{}, %{quality_profile_id: :string, name: :string}}
      |> cast(%{name: "ab"}, [:quality_profile_id, :name])
      |> validate_required([:quality_profile_id])
      |> validate_length(:name, min: 3)

    errors = UserError.from_changeset(changeset, ["input"])

    assert %UserError{
             code: :invalid_input,
             field: ["input", "qualityProfileId"],
             message: "quality_profile_id can't be blank"
           } in errors

    assert %UserError{
             code: :invalid_input,
             field: ["input", "name"],
             message: "name should be at least 3 character(s)"
           } in errors
  end

  test "cast_id accepts a UUID and refuses anything else" do
    id = Ecto.UUID.generate()

    assert UserError.cast_id(id, ["id"]) == {:ok, id}

    assert UserError.cast_id("nope", ["id"]) ==
             {:error, %UserError{code: :invalid_input, field: ["id"], message: "Not a valid id"}}
  end

  test "not_found names the thing and the argument" do
    assert UserError.not_found("episode", ["id"]) ==
             %UserError{code: :not_found, field: ["id"], message: "No episode has that id"}
  end
end
