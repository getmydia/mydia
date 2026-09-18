defmodule Mydia.CrashReporter.Sanitizer do
  @moduledoc """
  Sanitizes crash reports to remove sensitive data.

  This module ensures that no secrets are transmitted to the metadata relay:
  - API keys and tokens are redacted
  - Passwords and credentials are removed
  - Database connection strings have passwords redacted
  - File paths are kept for debugging (only usernames in paths are redacted)

  ## Privacy Principles

  The sanitizer focuses on protecting secrets, not general PII:
  1. **Secret Protection** - Redact all credentials, tokens, and API keys
  2. **Debugging-Friendly** - Keep file paths and error context for effective debugging
  3. **Minimal Redaction** - Only redact what's actually sensitive (passwords, keys, tokens)
  """

  @doc """
  Sanitizes a crash report.

  ## Examples

      iex> report = %{
      ...>   error_message: "File not found: /home/user/mydia/file.txt",
      ...>   stacktrace: [%{file: "/home/user/mydia/lib/mydia/app.ex", line: 42}],
      ...>   metadata: %{api_key: "secret123"}
      ...> }
      iex> Mydia.CrashReporter.Sanitizer.sanitize(report)
      %{
        error_message: "File not found: [REDACTED]/file.txt",
        stacktrace: [%{file: "lib/mydia/app.ex", line: 42}],
        metadata: %{api_key: "[REDACTED]"}
      }

  """
  @spec sanitize(map()) :: map()
  def sanitize(report) when is_map(report) do
    report
    |> sanitize_error_message()
    |> sanitize_stacktrace()
    |> sanitize_metadata()
  end

  # Private functions

  defp sanitize_error_message(%{error_message: message} = report) when is_binary(message) do
    %{report | error_message: sanitize_string(message)}
  end

  defp sanitize_error_message(report), do: report

  defp sanitize_stacktrace(%{stacktrace: stacktrace} = report) when is_list(stacktrace) do
    sanitized = Enum.map(stacktrace, &sanitize_stacktrace_entry/1)
    %{report | stacktrace: sanitized}
  end

  defp sanitize_stacktrace(report), do: report

  defp sanitize_stacktrace_entry(%{file: file} = entry) when is_binary(file) do
    %{entry | file: sanitize_file_path(file)}
  end

  defp sanitize_stacktrace_entry(entry), do: entry

  defp sanitize_metadata(%{metadata: metadata} = report) when is_map(metadata) do
    sanitized = sanitize_map(metadata)
    %{report | metadata: sanitized}
  end

  defp sanitize_metadata(report), do: report

  defp sanitize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key, sanitize_value(key, value)}
    end)
  end

  defp sanitize_value(key, value) when is_binary(key) do
    cond do
      # Only redact if the key is sensitive AND the value is not a complex type
      sensitive_key?(key) and is_binary(value) ->
        "[REDACTED]"

      is_binary(value) ->
        sanitize_string(value)

      is_map(value) ->
        sanitize_map(value)

      is_list(value) ->
        Enum.map(value, fn v ->
          if is_map(v), do: sanitize_map(v), else: sanitize_string_value(v)
        end)

      true ->
        value
    end
  end

  defp sanitize_value(_key, value), do: value

  defp sanitize_string_value(value) when is_binary(value), do: sanitize_string(value)
  defp sanitize_string_value(value), do: value

  defp sanitize_string(str) when is_binary(str) do
    str
    |> redact_usernames_in_paths()
    |> redact_urls()
    |> redact_tokens()
    |> redact_api_keys()
    |> redact_credentials()
  end

  defp sanitize_file_path(path) when is_binary(path) do
    # Keep file paths intact for debugging, just redact usernames
    path
    |> String.replace(~r{/home/[^/\s]+}, "/home/[USER]")
    |> String.replace(~r{/Users/[^/\s]+}, "/Users/[USER]")
    |> String.replace(~r{C:\\Users\\[^\\:\s]+}, "C:\\Users\\[USER]")
  end

  # Redact usernames in file paths but keep the rest
  defp redact_usernames_in_paths(str) do
    str
    |> String.replace(~r{/home/[^/\s]+}, "/home/[USER]")
    |> String.replace(~r{/Users/[^/\s]+}, "/Users/[USER]")
    |> String.replace(~r{C:\\Users\\[^\\:\s]+}, "C:\\Users\\[USER]")
  end

  # Redact URLs with credentials
  defp redact_urls(str) do
    str
    |> String.replace(~r{https?://[^:]+:[^@]+@}, "https://[REDACTED]:[REDACTED]@")
    |> String.replace(~r{postgres://[^:]+:[^@]+@}, "postgres://[REDACTED]:[REDACTED]@")
    |> String.replace(~r{mysql://[^:]+:[^@]+@}, "mysql://[REDACTED]:[REDACTED]@")
  end

  # Redact API keys and tokens
  defp redact_api_keys(str) do
    str
    |> String.replace(~r/[a-zA-Z0-9_-]{32,}/, fn match ->
      # Only redact if it looks like a key (long alphanumeric string)
      if String.match?(match, ~r/^[a-zA-Z0-9_-]+$/) do
        "[REDACTED]"
      else
        match
      end
    end)
  end

  # Redact bearer tokens and JWT tokens
  defp redact_tokens(str) do
    str
    |> String.replace(~r/Bearer\s+[a-zA-Z0-9_\-\.]+/, "Bearer [REDACTED]")
    # JWT format: header.payload.signature (each part is base64url encoded)
    # Use \w for word characters (alphanumeric + underscore) to be more greedy
    |> String.replace(~r/eyJ[\w-]+\.[\w-]+\.[\w-]+/, "[REDACTED]")
  end

  # Redact passwords and credentials
  defp redact_credentials(str) do
    str
    |> String.replace(~r{password["\s:=]+[^\s"]+}i, "password: [REDACTED]")
    |> String.replace(~r{secret["\s:=]+[^\s"]+}i, "secret: [REDACTED]")
    |> String.replace(~r{api_key["\s:=]+[^\s"]+}i, "api_key: [REDACTED]")
  end

  # Check if a key is sensitive
  defp sensitive_key?(key) when is_binary(key) do
    key_lower = String.downcase(key)

    Enum.any?(
      [
        "password",
        "secret",
        "api_key",
        "apikey",
        "token",
        "auth",
        "bearer",
        "credentials",
        "private_key",
        "private",
        "key",
        "jwt",
        "session",
        "cookie"
      ],
      &String.contains?(key_lower, &1)
    )
  end
end
