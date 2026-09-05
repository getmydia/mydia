defmodule Mydia.Accounts.UserLabelTest do
  # No database: label/1 reads struct fields only.
  use ExUnit.Case, async: true

  alias Mydia.Accounts.User

  defp user(attrs), do: struct!(%User{id: "9f4c2a10-1111-2222-3333-444455556666"}, attrs)

  test "prefers the username" do
    # Username first, so a local account keeps reading exactly as it does
    # today and the fallbacks only engage for accounts that render blank.
    label = User.label(user(username: "tonix", display_name: "Tonix R", email: "t@example.test"))

    assert label == "tonix"
  end

  test "falls back to the display name when there is no username" do
    assert User.label(user(username: nil, display_name: "Tonix R")) == "Tonix R"
  end

  test "falls back to the email when there is no username or display name" do
    assert User.label(user(username: nil, display_name: nil, email: "t@example.test")) ==
             "t@example.test"
  end

  test "falls back to an id prefix when the account has nothing else" do
    # OIDC only requires oidc_sub, so display_name and email are both
    # optional. Two such accounts must still be distinguishable in the
    # picker.
    assert User.label(user(username: nil, display_name: nil, email: nil)) == "user 9f4c2a10"
  end

  test "treats a blank field as absent" do
    assert User.label(user(username: "  ", display_name: "Tonix R")) == "Tonix R"

    assert User.label(user(username: nil, display_name: "", email: "t@example.test")) ==
             "t@example.test"
  end

  test "labels an unsaved struct without an id" do
    assert User.label(%User{}) == "unknown user"
  end
end
