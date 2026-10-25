defmodule MydiaWeb.AdminIndexersLive.ErrorMessages do
  @moduledoc """
  Operator-facing text for errors raised by the Indexers page: definition sync
  and FlareSolverr transport failures.
  """

  use Gettext, backend: MydiaWeb.Gettext

  # One whole sentence per known reason; an unknown reason is shown raw inside
  # the framing sentence.
  @spec sync_failed_message(term()) :: String.t()
  def sync_failed_message(:rate_limit_exceeded),
    do: gettext("Sync failed: GitHub API rate limit exceeded. Try again later.")

  def sync_failed_message(:not_found),
    do: gettext("Sync failed: Repository or definitions path not found.")

  def sync_failed_message({:unexpected_status, status}),
    do: gettext("Sync failed: Unexpected HTTP status: %{status}", status: status)

  def sync_failed_message(reason) when is_binary(reason),
    do: gettext("Sync failed: %{reason}", reason: reason)

  def sync_failed_message(reason), do: gettext("Sync failed: %{reason}", reason: inspect(reason))

  # Transport reasons are usually atoms (:econnrefused, :timeout) but can be
  # tuples, such as a TLS alert, which string interpolation cannot render.
  @spec format_transport_reason(term()) :: String.t()
  def format_transport_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_transport_reason(reason), do: inspect(reason)

  # A search that reached the site but parsed nothing is neither a success nor
  # an outage, and flattening it into "Connection successful" is what let five
  # indexers report a green test while every search returned zero results. The
  # flash component only has :info and :error (core_components.ex:45), so a
  # degraded result is :error with a message that says what is degraded; the
  # row's health badge carries the "degraded" state separately. The result
  # message and error text come from the health check and are shown as given.
  @spec library_test_flash(map()) :: {:info | :error, String.t()}
  def library_test_flash(%{success: true, status: "degraded"} = result) do
    {:error,
     gettext("%{message} (%{ms}ms)", message: result.message, ms: result.response_time_ms)}
  end

  def library_test_flash(%{success: true} = result) do
    {:info, gettext("%{message} (%{ms}ms)", message: result.message, ms: result.response_time_ms)}
  end

  def library_test_flash(result) do
    {:error,
     gettext("%{message}: %{error}",
       message: result.message,
       error: result.error || gettext("Unknown error")
     )}
  end
end
