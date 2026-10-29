defmodule Mydia.Indexers.Cardigann.Result.Format.Xml do
  @moduledoc false
  # XML adapter (RSS and Torznab feeds) over SweetXml. Behaviour is a port of
  # the XML helpers in `CardigannResultParser`.

  @behaviour Mydia.Indexers.Cardigann.Result.Format

  import SweetXml, only: [xpath: 2]

  require Logger

  alias Mydia.Indexers.Cardigann.Charset
  alias Mydia.Indexers.Cardigann.Result.Format.Template
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.Cardigann.Result.Plan.Rows

  @impl true
  def document(body, %Plan{} = plan) do
    {:ok, body |> Charset.decode(plan.encoding) |> SweetXml.parse()}
  rescue
    error -> {:error, "XML parse error: #{inspect(error)}"}
  catch
    :exit, reason -> {:error, "XML parse error: #{inspect(reason)}"}
  end

  @impl true
  def rows(document, %Rows{selector: selector}) do
    Logger.info("Extracting XML rows with selector: #{inspect(selector)}")
    found = xpath(document, rows_spec(selector))
    Logger.info("Found #{length(found)} XML rows before filtering")
    found
  end

  @impl true
  def raw(_document, row, field, opts \\ []) do
    case field.selector do
      selector when is_binary(selector) ->
        raw_value(row, Template.render(selector, opts), field.attribute)

      _ ->
        :not_found
    end
  end

  # `case` maps a key to a literal value, tested against the field's own
  # selector. The plan orders `*` last, so it is the fallback.
  @impl true
  def case_value(_document, row, field, opts \\ []) do
    selector = Template.render(field.selector || "", opts)

    field.case
    |> Enum.find_value(fn {key, value} ->
      if key == "*" or case_matches?(row, selector, field.attribute, Template.render(key, opts)),
        do: value
    end)
    |> case do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  defp case_matches?(row, selector, attribute, ":contains(" <> _ = key) do
    with {:ok, raw} <- raw_value(row, selector, attribute),
         [_, needle] <- Regex.run(~r/^:contains\(\s*['"]([^'"]*)['"]\s*\)$/, key) do
      String.contains?(String.downcase(raw), String.downcase(needle))
    else
      _ -> false
    end
  end

  defp case_matches?(row, selector, attribute, key) do
    case raw_value(row, selector, attribute) do
      {:ok, raw} -> raw == key or key_element_present?(row, selector, key)
      :not_found -> false
    end
  end

  # Presence, as Prowlarr's `QuerySelector(key) != null` tests it: an empty
  # `<key/>` still matches. `count()` because a string cast over an element node
  # raises in SweetXml.
  defp key_element_present?(row, selector, key) do
    path = if selector == "", do: ".//#{key}", else: "./#{selector}/#{key}"
    xpath(row, count_spec("count(#{path})")) > 0
  end

  defp raw_value(row, selector, attribute) do
    value = xpath(row, field_spec(selector, attribute))

    value =
      if value in [nil, ""], do: xpath_ignoring_namespace(row, selector, attribute), else: value

    case value do
      nil -> :not_found
      "" -> :not_found
      value when is_binary(value) -> {:ok, String.trim(value)}
      value when is_list(value) -> {:ok, value |> List.first() |> to_string() |> String.trim()}
      value -> {:ok, value |> to_string() |> String.trim()}
    end
  end

  # A CSS type selector (`raw_title`) matches an element by its local name, so
  # it finds `<tv:raw_title>` in a feed that declares an `xmlns:tv`. XPath's
  # `./raw_title` does not. This is the fallback for a plain element name, tried
  # only when the exact step found nothing, so an unprefixed element still wins.
  defp xpath_ignoring_namespace(row, selector, attribute) do
    if Regex.match?(~r/^[A-Za-z_][\w.-]*$/, selector) do
      step = "./*[local-name()='#{selector}']"

      path =
        if is_binary(attribute) and attribute != "",
          do: "#{step}/@#{attribute}",
          else: "#{step}/text()"

      xpath(row, string_spec(path))
    end
  end

  defp rows_spec(selector) do
    %SweetXpath{
      path: selector |> normalize_selector() |> then(&("//" <> &1)) |> String.to_charlist(),
      is_value: false,
      is_list: true,
      is_keyword: false,
      is_optional: false,
      cast_to: false
    }
  end

  # Prowlarr RSS definitions use CSS child combinators (`rss > channel > item`).
  # SweetXml expects XPath, so normalize ` > ` to `/` before querying.
  defp normalize_selector(selector) do
    selector
    |> String.trim()
    |> String.replace(" > ", "/")
    |> String.replace(" ", "")
    |> css_attrs_to_xpath()
  end

  defp field_spec(".", attribute) when is_binary(attribute) and attribute != "",
    do: string_spec("./@#{attribute}")

  defp field_spec(".", _attribute), do: string_spec("./text()")

  defp field_spec(selector, attribute) when is_binary(attribute) and attribute != "",
    do: string_spec("./#{selector}/@#{attribute}")

  defp field_spec(selector, _attribute), do: string_spec("./#{selector}/text()")

  # CSS attribute predicates as Cardigann XML definitions write them
  # ([name=seeders], [name="seeders"], [name]) to XPath. A predicate with no
  # element before it gets the wildcard step AngleSharp implies, which also
  # matches namespaced elements such as torznab:attr. Predicates that already
  # start with `@`, a digit or a function call are left alone.
  defp css_attrs_to_xpath(selector) do
    selector
    |> then(&Regex.replace(~r/(^|\/)\[/, &1, "\\1*["))
    |> then(&Regex.replace(~r/\[([A-Za-z_][\w:.-]*)\]/, &1, "[@\\1]"))
    |> then(
      &Regex.replace(
        ~r/\[([A-Za-z_][\w:.-]*)=(?:"([^"]*)"|'([^']*)'|([^\]"']*))\]/,
        &1,
        fn _full, name, double, single, bare ->
          "[@#{name}='#{double <> single <> bare}']"
        end
      )
    )
  end

  defp count_spec(path) do
    %SweetXpath{
      path: path |> css_attrs_to_xpath() |> String.to_charlist(),
      is_value: true,
      is_list: false,
      is_keyword: false,
      is_optional: false,
      cast_to: false
    }
  end

  defp string_spec(path) do
    %SweetXpath{
      path: path |> css_attrs_to_xpath() |> String.to_charlist(),
      is_value: true,
      is_list: false,
      is_keyword: false,
      is_optional: false,
      cast_to: :string
    }
  end
end
