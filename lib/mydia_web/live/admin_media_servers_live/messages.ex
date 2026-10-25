defmodule MydiaWeb.AdminMediaServersLive.Messages do
  @moduledoc """
  Translated flash and error text for the media servers page, kept out of the
  LiveView so that module stays under the size ratchet.

  Every function builds its text with the process locale, so call them from
  the LiveView process.
  """
  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.MediaServer.Error

  @doc "Shown when account mapping is attempted on an env or YAML server."
  def runtime_mapping do
    gettext(
      "Account mapping needs a database-managed server. Servers configured through env or YAML cannot store account links."
    )
  end

  # One message per server type: the noun is part of the sentence.
  def duplicate_user(%{type: :jellyfin}),
    do: gettext("Each Mydia user can be linked to only one Jellyfin account.")

  def duplicate_user(_config),
    do: gettext("Each Mydia user can be linked to only one account.")

  def duplicate_account(%{type: :jellyfin}),
    do: gettext("Each Jellyfin account can be linked to only one Mydia user.")

  def duplicate_account(_config),
    do: gettext("Each account can be linked to only one Mydia user.")

  def links_saved([], config),
    do: gettext("No accounts are linked to %{name}.", name: config.name)

  def links_saved(links, config) do
    ngettext(
      "Linked %{count} account on %{name}. Watched sync queued.",
      "Linked %{count} accounts on %{name}. Watched sync queued.",
      length(links),
      name: config.name
    )
  end

  def read_accounts_error(server, reason) do
    gettext("Could not read accounts from %{name}: %{reason}",
      name: server.name,
      reason: describe_reason(reason)
    )
  end

  defp describe_reason(%Error{} = error), do: Error.message(error)
  defp describe_reason(%Ecto.Changeset{}), do: gettext("the mapping could not be saved")

  defp describe_reason({:unsupported_provider, type}) do
    gettext("%{type} does not support per-user mapping", type: type)
  end

  defp describe_reason(reason) when is_atom(reason) do
    reason |> to_string() |> String.replace("_", " ")
  end

  defp describe_reason(reason), do: inspect(reason)
end
