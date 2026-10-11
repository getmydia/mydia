defmodule Mydia.Feedback.Sender do
  @moduledoc """
  Sends in-app feedback to the metadata relay.
  """

  require Logger

  @timeout 10_000

  @spec post(map()) :: {:ok, %{id: String.t()}} | {:error, term()}
  def post(payload) when is_map(payload) do
    url = feedback_url()

    headers = [
      {"content-type", "application/json"}
    ]

    body = Jason.encode!(payload)

    case Req.post(url, headers: headers, body: body, receive_timeout: @timeout) do
      {:ok, %{status: 201, body: response}} ->
        Logger.debug("Feedback sent successfully", response: response)
        {:ok, %{id: extract_id(response)}}

      {:ok, %{status: 400, body: response}} ->
        Logger.warning("Feedback validation failed", response: response)
        {:error, {:validation_error, extract_validation_errors(response)}}

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Feedback rate limited", retry_after: retry_after)
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status}} when status in [404, 503] ->
        Logger.warning("Feedback service unavailable", status: status)
        {:error, :service_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Feedback failed with unexpected HTTP status",
          status: status,
          body: inspect(body)
        )

        {:error, {:http_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("Feedback request timed out")
        {:error, :timeout}

      {:error, %{reason: reason}} ->
        Logger.error("Feedback request failed", reason: inspect(reason))
        {:error, {:request_failed, reason}}

      {:error, reason} ->
        Logger.error("Feedback request failed", reason: inspect(reason))
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Feedback send failed with exception",
        error: Exception.message(error),
        stacktrace: __STACKTRACE__
      )

      {:error, {:exception, error}}
  end

  defp feedback_url do
    "#{Mydia.Metadata.metadata_relay_url()}/feedback"
  end

  defp extract_id(response) when is_map(response) do
    Map.get(response, "id") || Map.get(response, :id) || "unknown"
  end

  defp extract_id(_response), do: "unknown"

  defp extract_validation_errors(response) when is_map(response) do
    Map.get(response, "errors") || Map.get(response, :errors) || response
  end

  defp extract_validation_errors(response), do: response

  defp get_retry_after(headers) do
    retry_header =
      headers
      |> header_entries()
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(to_string(key)) == "retry-after" do
          normalize_header_value(value)
        end
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

  defp header_entries(headers) when is_map(headers), do: Map.to_list(headers)

  defp normalize_header_value([value | _]), do: normalize_header_value(value)
  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value(value), do: to_string(value)
end
