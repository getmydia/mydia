defmodule Mydia.Logger do
  @moduledoc """
  Structured logging helper for Mydia application.

  Provides consistent logging with metadata across the application,
  especially for LiveView operations and critical system events.

  ## Usage

      # Log an error with context
      Mydia.Logger.log_error(:liveview, "Failed to update setting",
        error: error,
        user_id: user_id,
        operation: :update_setting
      )

      # Log with debug mode (controlled by environment variables)
      Mydia.Logger.debug("Detailed debug information", metadata)
  """

  require Logger

  @doc """
  Logs an error with structured metadata.

  ## Parameters

    * `category` - The category of the operation (e.g., :liveview, :download, :metadata)
    * `message` - Human-readable error message
    * `metadata` - Keyword list of metadata to include in logs

  ## Examples

      log_error(:liveview, "Failed to save quality profile",
        error: changeset.errors,
        user_id: socket.assigns.current_user.id,
        operation: :save_quality_profile
      )
  """
  def log_error(category, message, metadata \\ []) do
    enhanced_metadata =
      metadata
      |> Keyword.put(:category, category)
      |> Keyword.put(:timestamp, DateTime.utc_now())
      |> format_error_metadata()

    Logger.error(message, enhanced_metadata)

    # Log stack trace if available and debug mode is enabled
    if debug_mode?() && Keyword.has_key?(metadata, :stacktrace) do
      stacktrace = Keyword.get(metadata, :stacktrace)
      Logger.error("Stack trace: #{format_stacktrace(stacktrace)}", enhanced_metadata)
    end
  end

  @doc """
  Logs a warning with structured metadata.
  """
  def log_warning(category, message, metadata \\ []) do
    enhanced_metadata =
      metadata
      |> Keyword.put(:category, category)
      |> Keyword.put(:timestamp, DateTime.utc_now())

    Logger.warning(message, enhanced_metadata)
  end

  @doc """
  Logs info level message with structured metadata.
  """
  def log_info(category, message, metadata \\ []) do
    enhanced_metadata =
      metadata
      |> Keyword.put(:category, category)
      |> Keyword.put(:timestamp, DateTime.utc_now())

    Logger.info(message, enhanced_metadata)
  end

  @doc """
  Logs debug information, but only if debug mode is enabled.

  Debug mode can be enabled by setting the environment variable:
  - MYDIA_DEBUG=true
  - LOG_LEVEL=debug
  """
  def debug(message, metadata \\ []) do
    if debug_mode?() do
      enhanced_metadata =
        metadata
        |> Keyword.put(:timestamp, DateTime.utc_now())

      Logger.debug(message, enhanced_metadata)
    end
  end

  @doc """
  Checks if debug mode is enabled via environment variables.
  """
  def debug_mode? do
    System.get_env("MYDIA_DEBUG") == "true" ||
      System.get_env("LOG_LEVEL") == "debug"
  end

  @doc """
  Extracts user-friendly error message from various error types.

  ## Examples

      extract_error_message(%Ecto.Changeset{})
      #=> "Validation failed: name can't be blank, email is invalid"

      extract_error_message({:error, :not_found})
      #=> "not_found"

      extract_error_message(%RuntimeError{message: "Something went wrong"})
      #=> "Something went wrong"
  """
  def extract_error_message(%Ecto.Changeset{} = changeset) do
    errors =
      changeset.errors
      |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

    "Validation failed: #{errors}"
  end

  def extract_error_message({:error, reason}) when is_atom(reason) do
    reason |> to_string() |> String.replace("_", " ")
  end

  def extract_error_message({:error, reason}) when is_binary(reason) do
    reason
  end

  def extract_error_message(%{message: message}) when is_binary(message) do
    message
  end

  def extract_error_message(error) do
    inspect(error)
  end

  @doc """
  Creates user-friendly error message for flash notifications.

  Provides specific, actionable messages without exposing sensitive details.
  """
  def user_error_message(operation, error) do
    base_message = operation_message(operation)
    error_detail = sanitize_error_for_user(error)

    "#{base_message}: #{error_detail}"
  end

  ## Private functions

  defp format_error_metadata(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {key, format_metadata_value(value)} end)
  end

  defp format_metadata_value(%Ecto.Changeset{} = changeset) do
    %{
      valid?: changeset.valid?,
      errors: changeset.errors,
      changes: Map.keys(changeset.changes)
    }
  end

  defp format_metadata_value(value) when is_exception(value) do
    %{
      type: value.__struct__,
      message: Exception.message(value)
    }
  end

  defp format_metadata_value(value), do: value

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Exception.format_stacktrace()
  end

  defp format_stacktrace(stacktrace), do: inspect(stacktrace)

  defp operation_message(:update_setting), do: "Failed to update setting"
  defp operation_message(:save_quality_profile), do: "Failed to save quality profile"
  defp operation_message(:delete_quality_profile), do: "Failed to delete quality profile"
  defp operation_message(:duplicate_quality_profile), do: "Failed to duplicate quality profile"
  defp operation_message(:save_download_client), do: "Failed to save download client"
  defp operation_message(:delete_download_client), do: "Failed to delete download client"
  defp operation_message(:test_download_client), do: "Failed to test download client"
  defp operation_message(:save_indexer), do: "Failed to save indexer"
  defp operation_message(:delete_indexer), do: "Failed to delete indexer"
  defp operation_message(:test_indexer), do: "Failed to test indexer"
  defp operation_message(:remove_library_indexer), do: "Failed to remove indexer"
  defp operation_message(:save_library_path), do: "Failed to save library path"
  defp operation_message(:delete_library_path), do: "Failed to delete library path"
  defp operation_message(operation), do: "Operation failed: #{operation}"

  defp sanitize_error_for_user(%Ecto.Changeset{} = changeset) do
    errors =
      changeset.errors
      |> Enum.map_join(", ", fn {field, {msg, _}} ->
        "#{humanize_field(field)} #{msg}"
      end)

    if errors == "" do
      "Please check your input and try again"
    else
      errors
    end
  end

  defp sanitize_error_for_user({:error, :profile_in_use}) do
    "This quality profile is assigned to one or more media items. Please reassign those items first"
  end

  defp sanitize_error_for_user({:error, :not_found}) do
    "The requested item was not found"
  end

  defp sanitize_error_for_user({:error, reason}) when is_atom(reason) do
    reason
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp sanitize_error_for_user({:error, reason}) when is_binary(reason) do
    reason
  end

  defp sanitize_error_for_user(:multiple_failures) do
    "One or more settings failed to update. Please check your input and try again"
  end

  defp sanitize_error_for_user(%{message: message}) when is_binary(message) do
    message
  end

  defp sanitize_error_for_user(_error) do
    "An unexpected error occurred. Please try again or contact support if the problem persists"
  end

  defp humanize_field(field) when is_atom(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_field(field), do: to_string(field)
end
