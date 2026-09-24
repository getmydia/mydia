defmodule MydiaWeb.Api.LibraryExportController do
  @moduledoc """
  Downloads the library catalog as JSON or CSV. Admin only; accepts a browser
  session or an API key, so it backs both the Library Paths "Export" button and
  scripted backups.
  """

  use MydiaWeb, :controller

  alias Mydia.Library.Export

  def show(conn, params) do
    case parse_format(Map.get(params, "format", "json")) do
      {:ok, format} ->
        rows = Export.rows()
        send_export(conn, format, rows)

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Bad Request", message: "format must be json or csv"})
    end
  end

  defp parse_format("json"), do: {:ok, :json}
  defp parse_format("csv"), do: {:ok, :csv}
  defp parse_format(_), do: :error

  defp send_export(conn, format, rows) do
    {content_type, body} =
      case format do
        :json -> {"application/json", Export.to_json(rows)}
        :csv -> {"text/csv", Export.to_csv(rows)}
      end

    conn
    |> put_resp_content_type(content_type, "utf-8")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{Export.filename(format, DateTime.utc_now())}")
    )
    |> send_resp(200, body)
  end
end
