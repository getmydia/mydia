defmodule MydiaWeb.Schema.Resolvers.DeviceResolver do
  @moduledoc """
  GraphQL resolvers for device management.
  """

  alias Mydia.RemoteAccess

  @doc """
  Lists all devices for the current user.
  """
  def list_devices(_parent, _args, %{context: %{current_user: user}}) do
    devices =
      user.id
      |> RemoteAccess.list_devices()
      |> Enum.map(&format_device/1)

    {:ok, devices}
  end

  def list_devices(_parent, _args, _context) do
    {:error, :unauthorized}
  end

  @doc """
  Revokes a device, preventing future access.
  """
  def revoke_device(_parent, %{id: id}, %{context: %{current_user: user}}) do
    case RemoteAccess.get_device(id) do
      nil ->
        {:error, :not_found}

      device ->
        # Ensure the device belongs to the current user
        if device.user_id == user.id do
          case RemoteAccess.revoke_device(device) do
            {:ok, updated_device} ->
              {:ok, %{success: true, device: format_device(updated_device)}}

            {:error, changeset} ->
              {:error, message: "Failed to revoke device", details: changeset}
          end
        else
          {:error, :forbidden}
        end
    end
  end

  def revoke_device(_parent, _args, _context) do
    {:error, :unauthorized}
  end

  @doc """
  Records the calling device's iroh node ID.

  Keyed on the device inside the caller's own token rather than on an argument,
  so one device cannot rewrite another's address even within the same account.
  """
  def register_device_node(_parent, %{node_id: node_id}, %{
        context: %{current_user: user, device_id: device_id}
      })
      when is_binary(device_id) do
    case RemoteAccess.get_device(device_id) do
      nil ->
        {:error, :not_found}

      device when device.user_id != user.id ->
        {:error, :forbidden}

      device ->
        case RemoteAccess.register_node_id(device, node_id) do
          {:ok, updated} -> {:ok, format_device(updated)}
          {:error, changeset} -> {:error, message: "Invalid node ID", details: changeset}
        end
    end
  end

  def register_device_node(_parent, _args, _context) do
    # A plain user login carries no device_id, so there is nothing to record.
    {:error, :unauthorized}
  end

  # Format device for GraphQL response
  defp format_device(device) do
    %{
      id: device.id,
      device_name: device.device_name,
      platform: device.platform,
      last_seen_at: device.last_seen_at,
      is_revoked: not is_nil(device.revoked_at),
      created_at: device.inserted_at,
      node_id: device.node_id
    }
  end
end
