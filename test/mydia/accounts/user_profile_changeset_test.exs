defmodule Mydia.Accounts.UserProfileChangesetTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.User

  @user %User{
    id: "01914902-86ee-7359-b570-5cb65860d5c0",
    username: "testuser",
    email: "test@example.com",
    role: "user"
  }

  describe "profile_changeset/2" do
    test "accepts valid http and https URLs" do
      for url <- ["https://example.com/avatar.png", "http://example.com/avatar.jpg"] do
        changeset = User.profile_changeset(@user, %{avatar_url: url})
        assert changeset.valid?
        assert Ecto.Changeset.get_change(changeset, :avatar_url) == url
      end
    end

    test "accepts local /generated/avatars/ paths" do
      path = "/generated/avatars/avatar-#{@user.id}-1725312000.png"
      changeset = User.profile_changeset(@user, %{avatar_url: path})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :avatar_url) == path
    end

    test "normalizes empty string to nil" do
      user_with_avatar = %{@user | avatar_url: "https://example.com/avatar.png"}
      changeset = User.profile_changeset(user_with_avatar, %{avatar_url: ""})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :avatar_url) == nil
    end

    test "normalizes whitespace-only string to nil" do
      user_with_avatar = %{@user | avatar_url: "https://example.com/avatar.png"}
      changeset = User.profile_changeset(user_with_avatar, %{avatar_url: "   "})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :avatar_url) == nil
    end

    test "accepts nil to clear avatar" do
      user_with_avatar = %{@user | avatar_url: "https://example.com/avatar.png"}
      changeset = User.profile_changeset(user_with_avatar, %{avatar_url: nil})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :avatar_url) == nil
    end

    test "rejects invalid URLs or paths" do
      for invalid <- [
            "ftp://example.com/avatar.png",
            "/etc/passwd",
            "javascript:alert(1)",
            "not-a-url"
          ] do
        changeset = User.profile_changeset(@user, %{avatar_url: invalid})
        refute changeset.valid?
        assert %{avatar_url: ["must be a valid URL or local avatar path"]} = errors_on(changeset)
      end
    end

    test "validates display_name length" do
      long_name = String.duplicate("a", 101)
      changeset = User.profile_changeset(@user, %{display_name: long_name})
      refute changeset.valid?
      assert %{display_name: ["should be at most 100 character(s)"]} = errors_on(changeset)

      valid_name = String.duplicate("a", 100)
      changeset = User.profile_changeset(@user, %{display_name: valid_name})
      assert changeset.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
