defmodule MydiaWeb.Live.ErrorHandler do
  @moduledoc """
  Helper functions for handling errors gracefully in LiveViews.

  Provides utilities for wrapping dangerous operations, managing error state,
  and ensuring errors are logged properly without crashing the LiveView.

  ## Usage

      # Wrap a dangerous operation
      socket =
        handle_operation(socket, :load_profiles, fn ->
          Settings.list_quality_profiles()
        end)

      # Or with custom error handling
      socket =
        handle_operation(
          socket,
          :save_profile,
          fn -> Settings.create_quality_profile(params) end,
          success: fn socket, profile ->
            socket
            |> put_flash(:info, "Profile saved successfully")
            |> assign(:quality_profile, profile)
          end,
          error: fn socket, err ->
            socket
            |> put_flash(:error, "Failed to save profile")
          end
        )
  """

  alias Mydia.Logger, as: MydiaLogger

  @doc """
  Wraps a potentially failing operation with error handling.

  Automatically logs errors and can update socket state based on success/failure.

  ## Options

    * `:success` - Function to call on success, receives `(socket, result)`
    * `:error` - Function to call on error, receives `(socket, error)`
    * `:error_assign` - Assign name to store error (e.g., `:quality_profiles_error`)
    * `:log_category` - Category for logging (default: `:liveview`)
    * `:user_id` - User ID for logging (extracted from socket if not provided)

  ## Examples

      # Simple operation with default error handling
      socket = handle_operation(socket, :load_data, fn ->
        MyContext.load_data()
      end)

      # With custom success/error handlers
      socket = handle_operation(
        socket,
        :save_item,
        fn -> MyContext.save_item(params) end,
        success: fn socket, item ->
          socket
          |> put_flash(:info, "Saved!")
          |> assign(:item, item)
        end,
        error: fn socket, _err ->
          socket |> put_flash(:error, "Failed to save item")
        end
      )
  """
  def handle_operation(socket, operation_name, operation_fn, opts \\ []) do
    user_id = get_user_id(socket, opts)
    log_category = Keyword.get(opts, :log_category, :liveview)
    error_assign = Keyword.get(opts, :error_assign)

    try do
      result = operation_fn.()

      case result do
        {:ok, value} ->
          if success_fn = Keyword.get(opts, :success) do
            success_fn.(socket, value)
          else
            socket
          end

        {:error, error} ->
          handle_error(
            socket,
            operation_name,
            error,
            log_category,
            user_id,
            error_assign,
            opts
          )

        value ->
          # Operation succeeded without tuple wrapper
          if success_fn = Keyword.get(opts, :success) do
            success_fn.(socket, value)
          else
            socket
          end
      end
    rescue
      error ->
        handle_error(
          socket,
          operation_name,
          error,
          log_category,
          user_id,
          error_assign,
          Keyword.put(opts, :stacktrace, __STACKTRACE__)
        )
    end
  end

  @doc """
  Safely retrieves data with error boundary support.

  Returns `{:ok, data}` on success or `{:error, reason}` on failure,
  with automatic logging.
  """
  def safe_fetch(operation_name, fetch_fn, opts \\ []) do
    log_category = Keyword.get(opts, :log_category, :liveview)
    user_id = Keyword.get(opts, :user_id)

    try do
      case fetch_fn.() do
        {:ok, _} = success -> success
        {:error, _} = error -> error
        result -> {:ok, result}
      end
    rescue
      error ->
        MydiaLogger.log_error(log_category, "Failed to fetch data for #{operation_name}",
          error: error,
          operation: operation_name,
          user_id: user_id,
          stacktrace: __STACKTRACE__
        )

        {:error, Exception.message(error)}
    end
  end

  ## Private functions

  defp handle_error(socket, operation_name, error, log_category, user_id, error_assign, opts) do
    stacktrace = Keyword.get(opts, :stacktrace)

    # Log the error with full details
    metadata = [
      error: error,
      operation: operation_name,
      user_id: user_id
    ]

    metadata =
      if stacktrace do
        Keyword.put(metadata, :stacktrace, stacktrace)
      else
        metadata
      end

    MydiaLogger.log_error(
      log_category,
      "Operation failed: #{operation_name}",
      metadata
    )

    # Update socket based on configuration
    socket =
      if error_assign do
        Phoenix.Component.assign(socket, error_assign, MydiaLogger.extract_error_message(error))
      else
        socket
      end

    # Call custom error handler if provided
    if error_fn = Keyword.get(opts, :error) do
      error_fn.(socket, error)
    else
      socket
    end
  end

  defp get_user_id(socket, opts) do
    case Keyword.get(opts, :user_id) do
      nil ->
        case socket.assigns do
          %{current_user: %{id: id}} -> id
          _ -> nil
        end

      user_id ->
        user_id
    end
  end
end
