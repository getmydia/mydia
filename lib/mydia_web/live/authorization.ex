defmodule MydiaWeb.Live.Authorization do
  @moduledoc """
  Authorization helpers for LiveView event handlers.

  Provides functions to check user permissions and handle unauthorized access
  in LiveView contexts with appropriate flash messages and error responses.
  """

  import Phoenix.LiveView, only: [put_flash: 3]
  alias Mydia.Accounts.Authorization

  @doc """
  Checks if the current user can create media items.

  Returns `:ok` if authorized, or `{:unauthorized, socket}` with an error flash.
  Raises if current_user is not present in socket assigns.

  ## Examples

      def handle_event("create_movie", params, socket) do
        with :ok <- authorize_create_media(socket) do
          # Create media logic
          {:noreply, socket}
        else
          {:unauthorized, socket} -> {:noreply, socket}
        end
      end
  """
  def authorize_create_media(socket) do
    case Map.fetch(socket.assigns, :current_user) do
      {:ok, user} when not is_nil(user) ->
        if Authorization.can_create_media?(user) do
          :ok
        else
          socket = put_flash(socket, :error, "You do not have permission to add media items")
          {:unauthorized, socket}
        end

      _ ->
        raise "current_user is required in socket assigns for authorization"
    end
  end

  @doc """
  Checks if the current user can update media items.

  Returns `:ok` if authorized, or `{:unauthorized, socket}` with an error flash.
  Raises if current_user is not present in socket assigns.
  """
  def authorize_update_media(socket) do
    case Map.fetch(socket.assigns, :current_user) do
      {:ok, user} when not is_nil(user) ->
        if Authorization.can_update_media?(user) do
          :ok
        else
          socket = put_flash(socket, :error, "You do not have permission to modify media items")
          {:unauthorized, socket}
        end

      _ ->
        raise "current_user is required in socket assigns for authorization"
    end
  end

  @doc """
  Checks if the current user can delete media items.

  Returns `:ok` if authorized, or `{:unauthorized, socket}` with an error flash.
  Raises if current_user is not present in socket assigns.
  """
  def authorize_delete_media(socket) do
    case Map.fetch(socket.assigns, :current_user) do
      {:ok, user} when not is_nil(user) ->
        if Authorization.can_delete_media?(user) do
          :ok
        else
          socket = put_flash(socket, :error, "You do not have permission to delete media items")
          {:unauthorized, socket}
        end

      _ ->
        raise "current_user is required in socket assigns for authorization"
    end
  end

  @doc """
  Checks if the current user can trigger downloads or manage download clients.

  Only admin and user roles can trigger downloads.
  Returns `:ok` if authorized, or `{:unauthorized, socket}` with an error flash.
  Raises if current_user is not present in socket assigns.
  """
  def authorize_manage_downloads(socket) do
    case Map.fetch(socket.assigns, :current_user) do
      {:ok, user} when not is_nil(user) ->
        if Authorization.can_update_media?(user) do
          :ok
        else
          socket = put_flash(socket, :error, "You do not have permission to manage downloads")
          {:unauthorized, socket}
        end

      _ ->
        raise "current_user is required in socket assigns for authorization"
    end
  end

  @doc """
  Checks if the current user can import media files.

  Only admin and user roles can import media.
  Returns `:ok` if authorized, or `{:unauthorized, socket}` with an error flash.
  Raises if current_user is not present in socket assigns.
  """
  def authorize_import_media(socket) do
    case Map.fetch(socket.assigns, :current_user) do
      {:ok, user} when not is_nil(user) ->
        if Authorization.can_create_media?(user) do
          :ok
        else
          socket = put_flash(socket, :error, "You do not have permission to import media")
          {:unauthorized, socket}
        end

      _ ->
        raise "current_user is required in socket assigns for authorization"
    end
  end

  @doc """
  Checks if the current user can submit media requests.

  Only guests can submit requests; higher-level users are expected to create
  media directly. Returns `:ok` if authorized, or `{:unauthorized, socket}`
  with an error flash. Raises if current_user is not present in socket
  assigns.
  """
  def authorize_submit_request(socket) do
    case Map.fetch(socket.assigns, :current_user) do
      {:ok, user} when not is_nil(user) ->
        if Authorization.can_submit_request?(user) do
          :ok
        else
          socket = put_flash(socket, :error, "You do not have permission to request media")
          {:unauthorized, socket}
        end

      _ ->
        raise "current_user is required in socket assigns for authorization"
    end
  end

  @doc """
  Generic authorization check with custom permission function and error message.
  Raises if current_user is not present in socket assigns.

  ## Examples

      def handle_event("custom_action", params, socket) do
        with :ok <- authorize(socket, &Authorization.is_admin?/1, "Admin access required") do
          # Action logic
          {:noreply, socket}
        else
          {:unauthorized, socket} -> {:noreply, socket}
        end
      end
  """
  def authorize(socket, permission_fn, error_message) when is_function(permission_fn, 1) do
    case Map.fetch(socket.assigns, :current_user) do
      {:ok, user} when not is_nil(user) ->
        if permission_fn.(user) do
          :ok
        else
          socket = put_flash(socket, :error, error_message)
          {:unauthorized, socket}
        end

      _ ->
        raise "current_user is required in socket assigns for authorization"
    end
  end
end
