defmodule Mydia.Accounts.Avatar do
  @moduledoc """
  Manages avatar image storage and cleanup for user profiles.
  Avatars are stored under `<generated_media_path>/avatars/` and served via `/generated/avatars/...`.
  """

  alias Mydia.Accounts.User
  alias Mydia.Library.GeneratedMedia

  @allowed_extensions ~w(.jpg .jpeg .png .webp .gif)

  @doc """
  Returns the filesystem directory where avatar images are stored.
  """
  @spec storage_dir() :: Path.t()
  def storage_dir do
    Path.join([GeneratedMedia.base_path(), "avatars"])
  end

  @doc """
  Stores an uploaded avatar file for `user`, removing any previously uploaded avatar.
  Returns `{:ok, url_path}` where `url_path` is a relative path like `/generated/avatars/avatar-USER_ID-TIMESTAMP.ext`.
  """
  @spec store_avatar(User.t(), Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def store_avatar(%User{} = user, temp_path, original_filename) do
    ext =
      original_filename
      |> Path.extname()
      |> String.downcase()

    if ext in @allowed_extensions do
      dir = storage_dir()
      File.mkdir_p!(dir)

      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      timestamp = System.system_time(:millisecond)
      filename = "avatar-#{user.id}-#{timestamp}-#{suffix}#{ext}"
      target_path = Path.join(dir, filename)

      case File.copy(temp_path, target_path) do
        {:ok, _bytes} ->
          {:ok, "/generated/avatars/#{filename}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unsupported_format}
    end
  end

  @doc """
  Deletes an uploaded avatar file from disk if the URL is a local `/generated/avatars/` path,
  verifying that the file belongs to the given user.
  Silently returns `:ok` if `avatar_url` is nil, an external URL, or if the file does not exist.
  """
  @spec delete_avatar_file(User.t()) :: :ok
  def delete_avatar_file(%User{id: user_id, avatar_url: "/generated/avatars/" <> filename}) do
    safe_filename = Path.basename(filename)
    expected_prefix = "avatar-#{user_id}-"

    if String.starts_with?(safe_filename, expected_prefix) do
      target_path = Path.join(storage_dir(), safe_filename)

      case File.rm(target_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  def delete_avatar_file(%User{}), do: :ok
end
