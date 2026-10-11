defmodule Mydia.CrashReporter.Sender do
  @moduledoc """
  Sends crash reports to the metadata relay backend.

  Handles the HTTP communication with the metadata relay crash report endpoint.
  Includes retry logic and error handling.
  """

  require Logger

  @timeout 10_000

  @doc """
  Sends a crash report to the metadata relay.

  ## Parameters
  - `report`: The sanitized crash report map

  ## Returns
  - `{:ok, report_id}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> report = %{error_type: "RuntimeError", error_message: "test", stacktrace: []}
      iex> Mydia.CrashReporter.Sender.send_report(report)
      {:ok, "12345"}

  """
  @spec send_report(map()) :: {:ok, String.t()} | {:error, term()}
  def send_report(report) do
    url = get_crash_report_url()

    # Check if metadata relay is configured
    if url == "" do
      {:error, :metadata_relay_not_configured}
    else
      send_http_request(url, report)
    end
  end

  # Private functions

  defp send_http_request(url, report) do
    headers = [
      {"content-type", "application/json"}
    ]

    body = Jason.encode!(report)

    case Req.post(url, headers: headers, body: body, receive_timeout: @timeout) do
      {:ok, %{status: 201, body: response}} ->
        # Successfully created
        Logger.debug("Crash report sent successfully", response: response)
        {:ok, extract_report_id(response)}

      {:ok, %{status: 400, body: response}} ->
        # Validation error
        Logger.warning("Crash report validation failed", response: response)
        {:error, {:validation_error, response}}

      {:ok, %{status: 429, headers: headers}} ->
        # Rate limited
        retry_after = get_retry_after(headers)
        Logger.warning("Crash report rate limited", retry_after: retry_after)
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: 503}} ->
        # Service unavailable
        Logger.warning("Metadata relay service unavailable")
        {:error, :service_unavailable}

      {:ok, %{status: status, body: body}} ->
        # Other error - provide detailed context in the message
        body_summary =
          case body do
            %{} = map when map_size(map) > 0 ->
              # Extract error message if available
              Map.get(map, "error") || Map.get(map, "message") || inspect(map)

            binary when is_binary(binary) and byte_size(binary) > 0 ->
              # Show first 200 chars of response
              String.slice(binary, 0, 200)

            _ ->
              "empty or unknown response"
          end

        Logger.error(
          "Crash report failed with unexpected HTTP #{status} status: #{body_summary}",
          status: status,
          url: url,
          body: inspect(body)
        )

        {:error, {:http_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("Crash report request timed out")
        {:error, :timeout}

      {:error, %{reason: reason}} ->
        Logger.error("Crash report request failed", reason: inspect(reason))
        {:error, {:request_failed, reason}}

      {:error, reason} ->
        Logger.error("Crash report request failed", reason: inspect(reason))
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Crash report send failed with exception",
        error: Exception.message(error),
        stacktrace: __STACKTRACE__
      )

      {:error, {:exception, error}}
  end

  defp extract_report_id(response) when is_map(response) do
    Map.get(response, "id") || Map.get(response, :id) || "unknown"
  end

  defp extract_report_id(_), do: "unknown"

  defp get_retry_after(headers) do
    retry_header =
      Enum.find_value(headers, fn
        {"retry-after", value} -> value
        _ -> nil
      end)

    case retry_header do
      nil -> nil
      value when is_binary(value) -> String.to_integer(value)
      value when is_integer(value) -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp get_crash_report_url do
    case Mydia.Metadata.metadata_relay_url() do
      "" -> ""
      base_url -> "#{base_url}/crashes/report"
    end
  end
end
