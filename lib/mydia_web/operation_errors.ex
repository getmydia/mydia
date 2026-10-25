defmodule MydiaWeb.OperationErrors do
  @moduledoc """
  Translated flash text for failed admin operations.

  `Mydia.Logger.user_error_message/2` keeps the English sentences. This module
  is the web-side twin: one whole-sentence msgid per known operation, a
  translated reason for the known failure shapes, and the domain's raw text for
  reasons that arrive as data (a changeset's field errors, a provider message).
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias MydiaWeb.CoreComponents

  @doc """
  Shown when an account's restrictions block a title. Mirrors
  `Mydia.Media.restricted_message/0`; the JSON API keeps the domain's English.
  """
  @spec restricted_message() :: String.t()
  def restricted_message,
    do: gettext("This title is outside what your account is allowed to access.")

  @doc "The flash text for operation `operation` failing with `error`."
  @spec user_error_message(atom(), term()) :: String.t()
  def user_error_message(operation, error), do: message(operation, reason(error))

  defp message(:update_setting, reason),
    do: gettext("Failed to update setting: %{reason}", reason: reason)

  defp message(:save_quality_profile, reason),
    do: gettext("Failed to save quality profile: %{reason}", reason: reason)

  defp message(:delete_quality_profile, reason),
    do: gettext("Failed to delete quality profile: %{reason}", reason: reason)

  defp message(:duplicate_quality_profile, reason),
    do: gettext("Failed to duplicate quality profile: %{reason}", reason: reason)

  defp message(:save_download_client, reason),
    do: gettext("Failed to save download client: %{reason}", reason: reason)

  defp message(:delete_download_client, reason),
    do: gettext("Failed to delete download client: %{reason}", reason: reason)

  defp message(:test_download_client, reason),
    do: gettext("Failed to test download client: %{reason}", reason: reason)

  defp message(:save_indexer, reason),
    do: gettext("Failed to save indexer: %{reason}", reason: reason)

  defp message(:delete_indexer, reason),
    do: gettext("Failed to delete indexer: %{reason}", reason: reason)

  defp message(:test_indexer, reason),
    do: gettext("Failed to test indexer: %{reason}", reason: reason)

  defp message(:remove_library_indexer, reason),
    do: gettext("Failed to remove indexer: %{reason}", reason: reason)

  defp message(:save_library_path, reason),
    do: gettext("Failed to save library path: %{reason}", reason: reason)

  defp message(:delete_library_path, reason),
    do: gettext("Failed to delete library path: %{reason}", reason: reason)

  defp message(other, reason),
    do: gettext("Operation failed: %{operation}: %{reason}", operation: other, reason: reason)

  defp reason(%Ecto.Changeset{errors: errors}) do
    case Enum.map_join(errors, ", ", &changeset_error/1) do
      "" -> gettext("Please check your input and try again")
      text -> text
    end
  end

  defp reason({:error, :profile_in_use}) do
    gettext(
      "This quality profile is assigned to one or more media items. Please reassign those items first"
    )
  end

  defp reason({:error, :not_found}), do: gettext("The requested item was not found")

  defp reason({:error, reason}) when is_atom(reason) do
    reason |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp reason({:error, reason}) when is_binary(reason), do: reason

  defp reason(:multiple_failures) do
    gettext("One or more settings failed to update. Please check your input and try again")
  end

  defp reason(%{message: message}) when is_binary(message), do: message

  defp reason(_error) do
    gettext(
      "An unexpected error occurred. Please try again or contact support if the problem persists"
    )
  end

  defp changeset_error({field, {_msg, _opts} = error}) do
    "#{humanize_field(field)} #{CoreComponents.translate_error(error)}"
  end

  defp humanize_field(field) when is_atom(field) do
    field |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize_field(field), do: to_string(field)
end
