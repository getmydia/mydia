defmodule Mydia.Indexers.Cardigann.Login.Form do
  @moduledoc """
  The `form` login method: fetch the login page, scrape the form, fill it, submit.

  Mirrors Prowlarr's DoLogin "form" branch and GetConfigurationForSetup. A form with
  an image captcha or a one-time 2FA code pauses after the scrape and returns a
  `Challenge` holding the cookie jar, so the captcha image and the submit share one
  tracker session.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.{Charset, Selector}
  alias Mydia.Indexers.Cardigann.Login.{Challenge, Http, Inputs, Session, Verify}
  alias Mydia.Indexers.CardigannResultParser

  @twofa_keys ~w(2facode 2fa_code alt2fatoken)

  @spec begin(map()) :: {:ok, Session.t()} | {:needs_input, Challenge.t()} | {:error, Error.t()}
  def begin(%{parsed: parsed, config: config, base: base, definition: definition}) do
    login = parsed.login
    context = Inputs.context(parsed, config)
    ctx = Http.new_ctx(parsed, config, login.cookies)

    with {:ok, path} <- Inputs.render(login.path, context),
         {:ok, submitpath} <- Inputs.render(login.submitpath, context),
         login_url = Inputs.resolve(base, path),
         {:ok, landing, ctx} <- Http.request(ctx, :get, login_url, []),
         doc = parse_landing(landing.body, parsed),
         {:ok, form} <- find_form(doc, login.form, login_url),
         {:ok, scraped} <- apply_selector_inputs(scrape(doc, form), login.selectorinputs, doc),
         {:ok, query} <- apply_selector_inputs(%{}, login.getselectorinputs, doc),
         {:ok, ctx, image} <- maybe_captcha(ctx, login.captcha, doc, login_url) do
      pending = %{
        parsed: parsed,
        config: config,
        base: base,
        doc: doc,
        ctx: ctx,
        scraped: scraped,
        submit_url: submit_url(submitpath, form, login_url, query),
        twofa_key: twofa_key(login.inputs)
      }

      fields = Enum.reject([image && "captcha", pending.twofa_key && "2facode"], &is_nil/1)

      if fields == [] do
        submit(pending, %{})
      else
        {:needs_input,
         %Challenge{
           definition_id: definition.id,
           fields: fields,
           image: image && image.body,
           image_type: image && content_type(image),
           pending: pending
         }}
      end
    end
  rescue
    error in ArgumentError -> {:error, invalid_selector(error, __STACKTRACE__, parsed.id)}
  end

  # Selector raises ArgumentError for a selector lexbor rejects ("invalid selector ...")
  # or an undeclared :contains ("selector ... uses ..."). Any other ArgumentError is a
  # bug elsewhere and must not be mislabelled as a definition problem.
  defp invalid_selector(error, stacktrace, definition_id) do
    if Selector.selector_error?(error) do
      Error.invalid_config(
        "Invalid selector in the #{definition_id} login definition: #{Exception.message(error)}"
      )
    else
      reraise error, stacktrace
    end
  end

  @spec complete(Challenge.t(), map()) :: {:ok, Session.t()} | {:error, Error.t()}
  def complete(%Challenge{pending: pending}, answers), do: submit(pending, answers)

  defp submit(%{parsed: parsed} = p, answers) do
    login = parsed.login

    config =
      if p.twofa_key,
        do: Map.put(p.config, p.twofa_key, Map.get(answers, "2facode", "")),
        else: p.config

    context = Inputs.context(parsed, config)

    with {:ok, rendered} <- Inputs.render_map(login.inputs, context),
         {:ok, named} <- name_inputs(rendered, login.selectors, p.doc),
         {:ok, pairs} <- put_captcha(Map.merge(p.scraped, named), login, answers, p.doc),
         {:ok, resp, ctx} <- Http.request(p.ctx, :post, p.submit_url, form: pairs),
         {:ok, ctx} <- Verify.check(parsed, resp, ctx, p.base) do
      {:ok, %Session{method: :form, cookies: Http.cookies(ctx)}}
    end
  rescue
    error in ArgumentError -> {:error, invalid_selector(error, __STACKTRACE__, parsed.id)}
  end

  # Every selector the strategy will run goes to Selector.parse/2 up front, so any
  # `:contains` needle is declared.
  defp parse_landing(body, parsed) do
    login = parsed.login
    captcha = login.captcha || %{}

    selectors =
      [login.form, "input", captcha[:selector], captcha[:input]] ++
        Enum.map(login.selectorinputs, fn {_name, block} -> block.selector end) ++
        Enum.map(login.getselectorinputs, fn {_name, block} -> block.selector end) ++
        if(login.selectors, do: Map.keys(login.inputs), else: [])

    body |> Charset.decode(parsed.encoding) |> Selector.parse(selectors)
  end

  defp find_form(doc, selector, url) do
    case Selector.find(doc, :root, selector) do
      [form | _] ->
        {:ok, form}

      [] ->
        {:error, Error.authentication_failed("No login form found on #{url} using #{selector}")}
    end
  end

  defp scrape(doc, form) do
    for input <- Selector.find(doc, form, "input"),
        name = attr(input, "name"),
        name != nil,
        attr(input, "disabled") == nil,
        not unchecked_choice?(input),
        into: %{},
        do: {name, attr(input, "value") || ""}
  end

  defp unchecked_choice?(input),
    do:
      String.downcase(attr(input, "type") || "") in ["checkbox", "radio"] and
        attr(input, "checked") == nil

  defp apply_selector_inputs(acc, blocks, doc) do
    Enum.reduce_while(blocks, {:ok, acc}, fn {name, block}, {:ok, acc} ->
      case extract(doc, block) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, name, value)}}

        :none when block.optional == true ->
          {:cont, {:ok, acc}}

        :none ->
          {:halt,
           {:error,
            Error.authentication_failed("Login page has no #{block.selector} for #{name}")}}
      end
    end)
  end

  defp extract(doc, %{selector: selector} = block) do
    case Selector.find(doc, :root, selector) do
      [] ->
        :none

      [el | _] ->
        raw =
          if block[:attribute],
            do: attr(el, block.attribute) || "",
            else: Selector.text([el]) |> String.trim()

        # apply_filters/2 always returns {:ok, value}.
        {:ok, value} = CardigannResultParser.apply_filters(raw, block[:filters] || [])
        {:ok, to_string(value)}
    end
  end

  defp name_inputs(rendered, false, _doc), do: {:ok, rendered}

  defp name_inputs(rendered, true, doc) do
    Enum.reduce_while(rendered, {:ok, %{}}, fn {selector, value}, {:ok, acc} ->
      case field_name(doc, selector) do
        {:ok, name} -> {:cont, {:ok, Map.put(acc, name, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp field_name(doc, selector) do
    with [el | _] <- Selector.find(doc, :root, selector),
         name when is_binary(name) <- attr(el, "name") do
      {:ok, name}
    else
      _ -> {:error, Error.authentication_failed("Login page has no input matching #{selector}")}
    end
  end

  defp put_captcha(pairs, %{captcha: nil}, _answers, _doc), do: {:ok, pairs}

  defp put_captcha(pairs, %{captcha: captcha, selectors: selectors?}, answers, doc) do
    with {:ok, name} <-
           if(selectors?, do: field_name(doc, captcha.input), else: {:ok, captcha.input}) do
      {:ok, Map.put(pairs, name, Map.get(answers, "captcha", ""))}
    end
  end

  defp maybe_captcha(ctx, %{type: "image", selector: selector}, doc, login_url) do
    case Selector.find(doc, :root, selector) do
      [el | _] ->
        src = Inputs.resolve_page(login_url, attr(el, "src") || "")

        with {:ok, image, ctx} <- Http.request(ctx, :get, src, []) do
          {:ok, ctx, image}
        end

      [] ->
        # Prowlarr logs and carries on: some trackers only show the captcha after a failed attempt.
        {:ok, ctx, nil}
    end
  end

  defp maybe_captcha(ctx, nil, _doc, _url), do: {:ok, ctx, nil}

  defp maybe_captcha(_ctx, %{type: type}, _doc, _url),
    do: {:error, Error.invalid_config("Captcha type #{inspect(type)} is not supported")}

  # Both paths arrive rendered; an absent submitpath renders to "". Without one or
  # a form action, the form posts back to the page it came from.
  defp submit_url(submitpath, form, login_url, query) do
    path = if submitpath == "", do: attr(form, "action") || "", else: submitpath
    url = Inputs.resolve_page(login_url, path)

    if query == %{},
      do: url,
      else: url <> if(String.contains?(url, "?"), do: "&", else: "?") <> URI.encode_query(query)
  end

  @doc """
  True when a form login pauses for a person: an image captcha, or inputs that
  read a one-time 2FA code. The same rule decides when `begin/1` returns a
  `Challenge`.
  """
  @spec needs_person?(map() | nil) :: boolean()
  def needs_person?(%{method: "form"} = login),
    do: match?(%{type: "image"}, login[:captcha]) or twofa_key(login[:inputs] || %{}) != nil

  def needs_person?(_login), do: false

  defp twofa_key(inputs) do
    Enum.find(@twofa_keys, fn key -> references_config?(inputs, key) end)
  end

  defp references_config?(inputs, key),
    do: Enum.any?(inputs, fn {_k, v} -> String.contains?(v, ".Config." <> key) end)

  defp content_type(%{headers: headers}) do
    case Map.get(headers, "content-type") do
      [value | _] -> value |> String.split(";") |> hd()
      _ -> "application/octet-stream"
    end
  end

  defp attr(el, name), do: Selector.attribute([el], name)
end
