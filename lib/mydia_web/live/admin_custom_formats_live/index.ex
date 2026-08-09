defmodule MydiaWeb.AdminCustomFormatsLive.Index do
  @moduledoc """
  Admin page for the custom format library.

  Formats defined here are global. What a format *means* is per profile and is
  set in the quality profile editor, not here.
  """
  use MydiaWeb, :live_view

  alias Mydia.Settings.CustomFormats
  alias Mydia.Settings.CustomFormats.Matcher

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Custom Formats")
     |> assign(:active_tab, :custom_formats)
     |> assign(:editing, nil)
     |> assign(:test_title, "")
     |> assign(:test_results, [])
     |> load_formats()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, %{slug: nil, name: "", description: "", patterns: [], builtin?: false})
     |> assign(
       :form,
       to_form(%{"name" => "", "description" => "", "patterns_text" => ""},
         as: :custom_format
       )
     )
     |> assign(:test_title, "")
     |> assign(:test_results, [])}
  end

  def handle_event("edit", %{"slug" => slug}, socket) do
    format = CustomFormats.get(slug)

    {:noreply,
     socket
     |> assign(:editing, format)
     |> assign(
       :form,
       to_form(
         %{
           "name" => format.name,
           "description" => format.description || "",
           "patterns_text" => Enum.join(format.patterns, "\n")
         },
         as: :custom_format
       )
     )
     |> assign(:test_title, "")
     |> assign(:test_results, [])}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("validate", %{"custom_format" => params}, socket) do
    title = Map.get(params, "test_title", "")
    patterns = split_patterns(Map.get(params, "patterns_text", ""))

    {:noreply,
     socket
     |> assign(:form, to_form(params, as: :custom_format))
     |> assign(:test_title, title)
     |> assign(:test_results, test_patterns(patterns, title))}
  end

  def handle_event("save", %{"custom_format" => params}, socket) do
    attrs = %{
      name: save_name(socket.assigns.editing, params),
      description: Map.get(params, "description"),
      patterns: split_patterns(Map.get(params, "patterns_text", ""))
    }

    result =
      case socket.assigns.editing do
        %{slug: nil} -> CustomFormats.create_format(attrs)
        %{builtin?: true, slug: slug} -> CustomFormats.override_builtin(slug, attrs)
        %{slug: slug} -> CustomFormats.update_format(slug, attrs)
      end

    case result do
      {:ok, _format} ->
        {:noreply,
         socket
         |> put_flash(:info, "Format saved")
         |> assign(:editing, nil)
         |> load_formats()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, save_error_form(changeset, params, socket.assigns.editing))
         |> put_flash(:error, changeset_message(changeset))}

      # The format disappeared between opening the modal and submitting it:
      # another admin deleted it, or an upgrade dropped a built-in from the
      # manifest. Close the modal and re-read the list rather than letting the
      # unmatched tuple crash the LiveView.
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That format no longer exists. The list has been refreshed.")
         |> assign(:editing, nil)
         |> load_formats()}
    end
  end

  def handle_event("reset", %{"slug" => slug}, socket) do
    :ok = CustomFormats.reset_builtin(slug)

    {:noreply,
     socket
     |> put_flash(:info, "Format reset to the shipped definition")
     |> load_formats()}
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    case CustomFormats.delete_format(slug) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Format deleted") |> load_formats()}

      {:error, :builtin} ->
        {:noreply,
         put_flash(socket, :error, "Built-in formats cannot be deleted. Reset instead.")}
    end
  end

  defp load_formats(socket), do: assign(socket, :formats, CustomFormats.list_all())

  defp split_patterns(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp test_patterns(_patterns, ""), do: []

  defp test_patterns(patterns, title) do
    Enum.map(patterns, fn pattern ->
      case Matcher.compile_pattern(pattern) do
        {:ok, mp} ->
          format = %{slug: "test", name: "test", score: 0, reject: false, patterns: [mp]}

          %{
            pattern: pattern,
            status: if(Matcher.matches?(title, format), do: :match, else: :miss)
          }

        {:error, message} ->
          %{pattern: pattern, status: {:error, message}}
      end
    end)
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  defp save_name(%{builtin?: true, name: name}, _params), do: name
  defp save_name(_editing, params), do: Map.get(params, "name", "")

  defp save_error_form(changeset, params, editing) do
    patterns_text =
      Map.get(params, "patterns_text") ||
        changeset |> Ecto.Changeset.get_field(:patterns, []) |> Enum.join("\n")

    form_params = %{
      "name" => save_name(editing, params),
      "description" =>
        Map.get(params, "description", Ecto.Changeset.get_field(changeset, :description) || ""),
      "patterns_text" => patterns_text
    }

    errors =
      Enum.flat_map(changeset.errors, fn
        {:patterns, error} -> [{:patterns_text, error}]
        other -> [other]
      end)

    to_form(form_params, as: :custom_format, errors: errors, action: :insert)
  end
end
