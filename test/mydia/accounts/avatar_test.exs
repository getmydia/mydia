defmodule Mydia.Accounts.AvatarTest do
  use ExUnit.Case, async: false

  alias Mydia.Accounts
  alias Mydia.Accounts.Avatar
  alias Mydia.Accounts.User

  @user %User{
    id: "01914902-86ee-7359-b570-5cb65860d5c0",
    username: "avataruser",
    avatar_url: nil
  }

  setup do
    dir = Avatar.storage_dir()
    File.mkdir_p!(dir)

    on_exit(fn ->
      # Clean up any test files matching this user
      Path.wildcard(Path.join(dir, "avatar-#{@user.id}-*"))
      |> Enum.each(&File.rm/1)
    end)

    :ok
  end

  describe "store_avatar/3" do
    test "stores a valid image file and returns its /generated/avatars/ URL" do
      tmp_file = Path.join(System.tmp_dir!(), "test-avatar.png")
      # Minimal 1x1 PNG binary
      png_data =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5,
          0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      File.write!(tmp_file, png_data)

      assert {:ok, url_path} = Avatar.store_avatar(@user, tmp_file, "my_avatar.png")
      assert String.starts_with?(url_path, "/generated/avatars/avatar-#{@user.id}-")
      assert String.ends_with?(url_path, ".png")

      disk_path = Path.join(Avatar.storage_dir(), Path.basename(url_path))
      assert File.exists?(disk_path)
      assert File.read!(disk_path) == png_data
    end

    test "does not remove previous uploaded avatar file immediately when replacing with a new one" do
      tmp_file = Path.join(System.tmp_dir!(), "test-avatar-old.jpg")
      File.write!(tmp_file, "fake-jpg-content")

      {:ok, first_url} = Avatar.store_avatar(@user, tmp_file, "first.jpg")
      first_disk_path = Path.join(Avatar.storage_dir(), Path.basename(first_url))
      assert File.exists?(first_disk_path)

      user_with_first = %{@user | avatar_url: first_url}
      # Small delay to ensure timestamp difference
      :timer.sleep(10)

      {:ok, second_url} = Avatar.store_avatar(user_with_first, tmp_file, "second.png")
      second_disk_path = Path.join(Avatar.storage_dir(), Path.basename(second_url))

      assert File.exists?(second_disk_path)
      assert File.exists?(first_disk_path)
    end

    test "rejects unsupported file extension" do
      tmp_file = Path.join(System.tmp_dir!(), "script.sh")
      File.write!(tmp_file, "#!/bin/sh\necho hello")

      assert {:error, :unsupported_format} = Avatar.store_avatar(@user, tmp_file, "script.sh")
    end

    test "generates distinct filenames and URLs for concurrent uploads" do
      tmp_file = Path.join(System.tmp_dir!(), "concurrent-avatar.png")
      File.write!(tmp_file, "avatar-content")

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Avatar.store_avatar(@user, tmp_file, "avatar.png")
          end)
        end

      results = Task.await_many(tasks)
      urls = Enum.map(results, fn {:ok, url} -> url end)

      assert length(Enum.uniq(urls)) == 5
    end
  end

  describe "delete_avatar_file/1" do
    test "ignores external URLs safely without error" do
      assert :ok ==
               Avatar.delete_avatar_file(%{@user | avatar_url: "https://example.com/avatar.jpg"})

      assert :ok == Avatar.delete_avatar_file(%{@user | avatar_url: nil})
    end

    test "accepts user struct directly and removes file from disk" do
      filename = "avatar-#{@user.id}-9876543210.png"
      path = Path.join(Avatar.storage_dir(), filename)
      File.write!(path, "user-avatar-bytes")
      assert File.exists?(path)

      user = %{@user | avatar_url: "/generated/avatars/#{filename}"}
      assert :ok == Avatar.delete_avatar_file(user)
      refute File.exists?(path)
    end

    test "refuses to delete an avatar belonging to another user ID (IDOR protection)" do
      other_user_id = "01914902-86ee-7359-b570-5cb65860d999"
      filename = "avatar-#{other_user_id}-1234567890.jpg"
      path = Path.join(Avatar.storage_dir(), filename)
      File.write!(path, "other-user-avatar-bytes")
      assert File.exists?(path)

      # Attempt to delete the file using @user struct but pointing to the other user's file
      user = %{@user | avatar_url: "/generated/avatars/#{filename}"}
      assert :ok == Avatar.delete_avatar_file(user)

      # The file should still exist
      assert File.exists?(path)

      # Clean up
      File.rm(path)
    end

    test "Mydia.Accounts.delete_avatar_file/1 delegates properly for user" do
      filename = "avatar-#{@user.id}-1122334455.webp"
      path = Path.join(Avatar.storage_dir(), filename)
      File.write!(path, "delegated-bytes")
      assert File.exists?(path)

      user = %{@user | avatar_url: "/generated/avatars/#{filename}"}
      assert :ok == Accounts.delete_avatar_file(user)
      refute File.exists?(path)
    end
  end
end
