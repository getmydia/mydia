defmodule MydiaWeb.AdminIndexersLive.FlareSolverrMessages do
  @moduledoc """
  Flash text for the FlareSolverr row and modal on the Indexers page, kept out
  of `AdminIndexersLive.Index` so that large module does not grow with its
  translations.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias MydiaWeb.AdminIndexersLive.ErrorMessages

  @doc "The flash for a save whose runtime-config reload gave `:ok` or `{:error, _}`."
  @spec save_flash(:ok | {:error, term()}) :: {:info | :error, String.t()}
  def save_flash(:ok), do: {:info, gettext("FlareSolverr settings saved")}

  def save_flash({:error, _reason}) do
    {:error,
     gettext(
       "FlareSolverr settings saved, but the runtime config could not be reloaded because the merged configuration is invalid. The change will take effect once the configuration is valid. Check the logs for the validation error."
     )}
  end

  @doc """
  The flash for one reading of a `FlareSolverr.health_check/1` result, shared by
  the row's and the modal's Test buttons.
  """
  @spec test_flash(term()) :: {:info | :error, String.t()}
  def test_flash({:ok, info}) do
    {:info,
     gettext(
       "FlareSolverr connection successful! Version: %{version}, Active sessions: %{sessions}",
       version: info[:version] || gettext("unknown"),
       sessions: length(info[:sessions] || [])
     )}
  end

  def test_flash({:error, :invalid_url}) do
    {:error, gettext("Not a valid FlareSolverr URL. Use the form http://flaresolverr:8191.")}
  end

  def test_flash({:error, {:connection_error, reason}}) do
    {:error,
     gettext("FlareSolverr connection failed: %{reason}",
       reason: ErrorMessages.format_transport_reason(reason)
     )}
  end

  def test_flash({:error, {:http_error, status, _body}}) do
    {:error, gettext("FlareSolverr returned HTTP %{status}", status: status)}
  end

  def test_flash({:error, reason}) do
    {:error, gettext("FlareSolverr test failed: %{reason}", reason: inspect(reason))}
  end

  @doc "Whether `test_flash/1` has a specific message for this error (the rest are logged)."
  @spec known_test_error?(term()) :: boolean()
  def known_test_error?(:invalid_url), do: true
  def known_test_error?({:connection_error, _reason}), do: true
  def known_test_error?({:http_error, _status, _body}), do: true
  def known_test_error?(_reason), do: false
end
