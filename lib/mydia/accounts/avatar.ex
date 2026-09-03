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

      # Clean up any existing uploaded avatar for this user
      delete_avatar_file(user.avatar_url)

      timestamp = System.system_time(:millisecond)
      filename = "avatar-#{user.id}-#{timestamp}#{ext}"
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
  or given a user struct whose avatar_url is set.
  Silently returns `:ok` if `avatar_url` is nil, an external URL, or if the file does not exist.
  """
  @spec delete_avatar_file(User.t() | String.t() | nil) :: :ok
  def delete_avatar_file(%User{avatar_url: avatar_url}), do: delete_avatar_file(avatar_url)
  def delete_avatar_file(nil), do: :ok

  def delete_avatar_file("/generated/avatars/" <> filename) do
    # Prevent path traversal by extracting the basename only
    safe_filename = Path.basename(filename)
    target_path = Path.join(storage_dir(), safe_filename)

    case File.rm(target_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  def delete_avatar_file(_external_url), do: :ok
end
