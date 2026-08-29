defmodule Mydia.Indexers.CardigannTemplate do
  @moduledoc """
  Template engine for Cardigann Go-style templates.

  Uses NimbleParsec for robust template parsing, supporting Go's text/template syntax
  used by Cardigann/Prowlarr definitions.

  ## Supported Features

  ### Variables
  - `.Keywords` - Search query
  - `.Config.X` - User configuration values
  - `.Query.X` - Query parameters (Series, Season, Ep, IMDB, TMDB, etc.)
  - `.Categories` - Selected category IDs
  - `.Today.Year` - Current year
  - `.True` / `.False` - Boolean literals

  ### Functions
  - `or` - Logical OR: `{{ or .A .B .C }}`
  - `and` - Logical AND: `{{ and .A .B }}`
  - `not` - Logical NOT: `{{ not .A }}`
  - `eq`, `ne`, `lt`, `le`, `gt`, `ge` - Comparisons
  - `re_replace` - Regex replacement: `{{ re_replace .Var "pattern" "replacement" }}`
  - `join` - Join collection: `{{ join .Categories "," }}`
  - `len` - Length: `{{ len .Items }}`
  - `index` - Index access: `{{ index .Items 0 }}`
  - `print`, `printf`, `println` - Formatting

  ### Control Structures
  - `{{ if .Var }}...{{ else }}...{{ end }}`
  - `{{ if or .A .B }}...{{ else }}...{{ end }}`
  - `{{ range .Items }}...{{ else }}...{{ end }}`
  - `{{ with .Var }}...{{ else }}...{{ end }}`

  ### Advanced
  - Pipelines: `{{ .Value | func1 | func2 }}`
  - Comments: `{{/* comment */}}`
  - Whitespace trimming: `{{-` and `-}}`

  ## Examples

      iex> context = %{keywords: "Ubuntu", config: %{"sort" => "seeders"}}
      iex> render("/search/{{ .Keywords }}/{{ .Config.sort }}/", context)
      {:ok, "/search/Ubuntu/seeders/"}
  """

  import NimbleParsec
  require Logger

  @type context :: %{
          optional(:keywords) => String.t() | nil,
          optional(:config) => map(),
          optional(:query) => map(),
          optional(:categories) => [integer()],
          optional(:settings) => [map()],
          optional(atom()) => any()
        }

  # Parser setup - tokenize the template
  ws = ascii_string([?\s, ?\t, ?\n, ?\r], min: 1)
  optional_ws = optional(ws)

  # String literals
  string_lit =
    ignore(string("\""))
    |> repeat(
      choice([
        string("\\\"") |> replace(?"),
        string("\\\\") |> replace(?\\),
        string("\\n") |> replace(?\n),
        string("\\t") |> replace(?\t),
        string("\\r") |> replace(?\r),
        utf8_char(not: ?")
      ])
    )
    |> ignore(string("\""))
    |> reduce({List, :to_string, []})

  # Field path: .Field or .Field.Nested
  field_path =
    string(".")
    |> optional(
      ascii_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 1)
      |> repeat(
        ignore(string("."))
        |> ascii_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 1)
      )
    )
    |> reduce(:build_field_path)

  # Integer literal (for index function)
  integer_lit =
    optional(string("-"))
    |> ascii_string([?0..?9], min: 1)
    |> reduce(:build_integer)

  # Simple value: field, string, integer, parenthesized expression, or identifier
  simple_value =
    choice([
      string_lit |> unwrap_and_tag(:string),
      integer_lit,
      parsec(:paren_expr),
      field_path
    ])

  # Function call inside parentheses (args stop at closing paren)
  paren_function_call =
    ascii_string([?a..?z, ?A..?Z, ?_], min: 1)
    |> lookahead(ws)
    |> concat(parsec(:paren_func_args))
    |> tag(:call)

  # Parenthesized expression: (expr) - strips parens, evaluates inner expression
  defcombinatorp(
    :paren_expr,
    ignore(string("("))
    |> ignore(optional_ws)
    |> concat(parsec(:paren_inner_expr))
    |> ignore(optional_ws)
    |> ignore(string(")"))
  )

  # Content inside parentheses: function call or simple value
  defcombinatorp(
    :paren_inner_expr,
    choice([
      paren_function_call,
      simple_value
    ])
  )

  # Function arguments inside parentheses (stop at closing paren)
  defcombinatorp(
    :paren_func_args,
    ignore(ws)
    |> concat(simple_value)
    |> repeat(
      lookahead_not(string(")"))
      |> ignore(ws)
      |> concat(simple_value)
    )
  )

  # Function arguments (space-separated values)
  defcombinatorp(
    :func_args,
    ignore(ws)
    |> concat(simple_value)
    |> ignore(optional_ws)
    |> repeat(
      lookahead_not(choice([string("|"), string("}}"), string("-}}")]))
      |> ignore(optional(ws))
      |> concat(simple_value)
      |> ignore(optional_ws)
    )
  )

  # Function call: funcname arg1 arg2
  function_call =
    ascii_string([?a..?z, ?A..?Z, ?_], min: 1)
    |> lookahead(ws)
    |> concat(parsec(:func_args))
    |> tag(:call)

  # Pipeline stage: value or function
  pipeline_stage =
    choice([
      function_call,
      simple_value
    ])

  # Full expression with optional pipeline
  expression =
    pipeline_stage
    |> repeat(
      ignore(optional_ws)
      |> ignore(string("|"))
      |> ignore(optional_ws)
      |> concat(pipeline_stage)
    )
    |> tag(:expr)

  # Action content (what's inside {{ }})
  action_content =
    ignore(optional_ws)
    |> choice([
      # Control keywords
      string("if") |> replace(:if) |> concat(optional(ignore(ws) |> concat(expression))),
      string("else if")
      |> replace(:else_if)
      |> concat(optional(ignore(ws) |> concat(expression))),
      string("else") |> replace(:else),
      string("end") |> replace(:end),
      string("range") |> replace(:range) |> concat(optional(ignore(ws) |> concat(expression))),
      string("with") |> replace(:with) |> concat(optional(ignore(ws) |> concat(expression))),
      # Regular expression
      expression
    ])
    |> ignore(optional_ws)

  # Actions with trimming support
  action =
    choice([
      string("{{-")
      |> ignore()
      |> concat(action_content)
      |> ignore(string("-}}"))
      |> tag(:action_trim_both),
      string("{{-")
      |> ignore()
      |> concat(action_content)
      |> ignore(string("}}"))
      |> tag(:action_trim_left),
      string("{{")
      |> ignore()
      |> concat(action_content)
      |> ignore(string("-}}"))
      |> tag(:action_trim_right),
      string("{{") |> ignore() |> concat(action_content) |> ignore(string("}}")) |> tag(:action)
    ])

  # Comments
  comment =
    choice([
      string("{{") |> optional(string("-")) |> ignore(optional_ws) |> string("/*"),
      lookahead_not(string("/*"))
    ])
    |> repeat(lookahead_not(string("*/")) |> utf8_char([]))
    |> ignore(string("*/"))
    |> ignore(optional_ws)
    |> optional(string("-"))
    |> ignore(string("}}"))
    |> ignore()

  # Plain text (must match at least 1 character to avoid infinite loop)
  text =
    times(lookahead_not(choice([string("{{"), eos()])) |> utf8_char([]), min: 1)
    |> reduce({List, :to_string, []})
    |> post_traverse(:tag_text)

  # Main template parser
  defparsec(
    :parse_template,
    repeat(choice([comment, action, text]))
    |> eos()
  )

  # Helpers
  defp build_field_path(["."]), do: {:field, []}
  defp build_field_path(["." | segments]), do: {:field, segments}
  defp build_field_path(parts), do: {:field, parts}

  defp build_integer([num_str]), do: {:integer, String.to_integer(num_str)}
  defp build_integer(["-", num_str]), do: {:integer, -String.to_integer(num_str)}

  defp tag_text(rest, [""], context, _line, _offset), do: {rest, [], context}
  defp tag_text(rest, [text], context, _line, _offset), do: {rest, [{:text, text}], context}

  @doc """
  Renders a Cardigann template string with the given context.
  """
  @spec render(String.t(), context(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(template, context, opts \\ []) when is_binary(template) do
    url_encode? = Keyword.get(opts, :url_encode, true)

    case parse_template(template) do
      {:ok, tokens, "", _, _, _} ->
        {:ok, evaluate_tokens(tokens, context, url_encode?)}

      {:ok, _, rest, _, {line, _}, offset} ->
        error_msg =
          "parse error at line #{line}, offset #{offset}: unexpected '#{String.slice(rest, 0, 20)}'"

        Logger.info("Template parse failed: #{error_msg}",
          template: String.slice(template, 0, 100),
          line: line,
          offset: offset
        )

        {:error, error_msg}

      {:error, reason, _, _, {line, _}, offset} ->
        error_msg = "parse error at line #{line}, offset #{offset}: #{reason}"

        Logger.info("Template parse failed: #{error_msg}",
          template: String.slice(template, 0, 100),
          line: line,
          offset: offset
        )

        {:error, error_msg}
    end
  rescue
    e ->
      Logger.error("Template error: #{inspect(e)}\n#{Exception.format_stacktrace()}")
      {:error, {:template_error, Exception.message(e)}}
  end

  # Evaluate tokens directly
  defp evaluate_tokens(tokens, context, url_encode?) do
    {result, _ctx} = eval_tokens(tokens, context, url_encode?, [])
    IO.iodata_to_binary(result)
  end

  # Recursively evaluate tokens
  defp eval_tokens([], ctx, _url_encode?, acc), do: {Enum.reverse(acc), ctx}

  defp eval_tokens([{:text, text} | rest], ctx, url_encode?, acc) do
    eval_tokens(rest, ctx, url_encode?, [text | acc])
  end

  # Simple field reference - apply URL encoding if requested
  defp eval_tokens([{action_type, [{:expr, [{:field, path}]}]} | rest], ctx, url_encode?, acc)
       when action_type in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    value = resolve_field(path, ctx)
    output = format_output(value, url_encode?)
    eval_tokens(rest, ctx, url_encode?, [output | acc])
  end

  # Function call or pipeline. Encodes exactly like a bare field reference: in a
  # path context the caller asks for encoding, and a value that reached the
  # template through `or`, `re_replace` or `join` is no less user-supplied than
  # one that came straight from `.Keywords`.
  #
  # This is load-bearing. CardigannOverrides.patch_1337x/1 routes keywords
  # through `{{ or .Query.Album .Query.Artist .Keywords }}`, so leaving function
  # results raw put an unescaped query into the URL path and every 1337x search
  # failed with {:invalid_request_target, "/search/Some Title: Here/1/"}.
  #
  # Query parameters are unaffected: build_query_params/2 renders them with
  # url_encode: false and lets Req do the escaping.
  defp eval_tokens([{action_type, [{:expr, expr_parts}]} | rest], ctx, url_encode?, acc)
       when action_type in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    value = eval_expression(expr_parts, ctx)
    output = format_output(value, url_encode?)
    eval_tokens(rest, ctx, url_encode?, [output | acc])
  end

  # If conditional
  defp eval_tokens([{action_type, [:if, {:expr, cond_expr}]} | rest], ctx, url_encode?, acc)
       when action_type in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    condition_value = eval_expression(cond_expr, ctx)

    {true_branch, after_else, rest2} = collect_if_branches(rest)

    branch = if truthy?(condition_value), do: true_branch, else: after_else
    {branch_result, _} = eval_tokens(branch, ctx, url_encode?, [])

    eval_tokens(rest2, ctx, url_encode?, [branch_result | acc])
  end

  # If without condition (just "if" keyword)
  defp eval_tokens([{_action_type, [:if]} | rest], ctx, url_encode?, acc) do
    # Malformed if, skip it
    eval_tokens(rest, ctx, url_encode?, acc)
  end

  # Range loop
  defp eval_tokens([{_action_type, [:range, {:expr, range_expr}]} | rest], ctx, url_encode?, acc) do
    collection = eval_expression(range_expr, ctx)
    {body, after_else, rest2} = collect_until_end(rest)

    # Store root context for $ access inside range blocks
    root = Map.get(ctx, :root, ctx)

    output =
      case collection do
        list when is_list(list) and list != [] ->
          Enum.map(list, fn item ->
            item_ctx = ctx |> Map.put(:dot, item) |> Map.put(:root, root)
            {result, _} = eval_tokens(body, item_ctx, url_encode?, [])
            result
          end)

        empty when (is_list(empty) and empty == []) or is_nil(empty) ->
          # Empty list or nil - execute else branch if present
          if after_else != [] do
            {result, _} = eval_tokens(after_else, ctx, url_encode?, [])
            result
          else
            ""
          end

        _ ->
          ""
      end

    eval_tokens(rest2, ctx, url_encode?, [output | acc])
  end

  # With block
  defp eval_tokens([{_action_type, [:with, {:expr, with_expr}]} | rest], ctx, url_encode?, acc) do
    value = eval_expression(with_expr, ctx)
    {body, else_body, rest2} = collect_until_end(rest)

    # Store root context for $ access inside with blocks
    root = Map.get(ctx, :root, ctx)

    output =
      if truthy?(value) do
        with_ctx = ctx |> Map.put(:dot, value) |> Map.put(:root, root)
        {result, _} = eval_tokens(body, with_ctx, url_encode?, [])
        result
      else
        {result, _} = eval_tokens(else_body, ctx, url_encode?, [])
        result
      end

    eval_tokens(rest2, ctx, url_encode?, [output | acc])
  end

  # Skip else and end keywords (handled by control structures)
  defp eval_tokens([{_action_type, [:else]} | rest], ctx, url_encode?, acc) do
    eval_tokens(rest, ctx, url_encode?, acc)
  end

  defp eval_tokens([{_action_type, [:end]} | rest], ctx, url_encode?, acc) do
    eval_tokens(rest, ctx, url_encode?, acc)
  end

  # Unknown action
  defp eval_tokens([other | rest], ctx, url_encode?, acc) do
    Logger.warning("Unknown token: #{inspect(other)}")
    eval_tokens(rest, ctx, url_encode?, acc)
  end

  # Collect if/else/end branches (with nesting depth tracking)
  defp collect_if_branches(tokens) do
    {true_branch, rest} = collect_until_else_or_end_at_depth(tokens, [], 0)

    case rest do
      [{_tag, [:else]} | after_else] ->
        {false_branch, rest2} = collect_until_end_at_depth(after_else, [], 0)
        {true_branch, false_branch, rest2}

      [{_tag, [:end]} | rest2] ->
        {true_branch, [], rest2}

      _ ->
        {true_branch, [], rest}
    end
  end

  # Collect until end (for range, with) - with nesting depth tracking
  defp collect_until_end(tokens) do
    {body, rest} = collect_until_else_or_end_at_depth(tokens, [], 0)

    case rest do
      [{_tag, [:else]} | after_else] ->
        {else_body, rest2} = collect_until_end_at_depth(after_else, [], 0)
        {body, else_body, rest2}

      [{_tag, [:end]} | rest2] ->
        {body, [], rest2}

      _ ->
        {body, [], rest}
    end
  end

  # Collect tokens until else or end at depth 0 (tracking nesting)
  defp collect_until_else_or_end_at_depth([], acc, _depth), do: {Enum.reverse(acc), []}

  # At depth 0, stop at else or end
  defp collect_until_else_or_end_at_depth([{tag, [:else]} | _] = rest, acc, 0)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    {Enum.reverse(acc), rest}
  end

  defp collect_until_else_or_end_at_depth([{tag, [:end]} | _] = rest, acc, 0)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    {Enum.reverse(acc), rest}
  end

  # Increase depth on if/range/with
  defp collect_until_else_or_end_at_depth([{tag, [:if | _]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    collect_until_else_or_end_at_depth(rest, [token | acc], depth + 1)
  end

  defp collect_until_else_or_end_at_depth([{tag, [:range | _]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    collect_until_else_or_end_at_depth(rest, [token | acc], depth + 1)
  end

  defp collect_until_else_or_end_at_depth([{tag, [:with | _]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    collect_until_else_or_end_at_depth(rest, [token | acc], depth + 1)
  end

  # Decrease depth on end (when depth > 0)
  defp collect_until_else_or_end_at_depth([{tag, [:end]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] and
              depth > 0 do
    collect_until_else_or_end_at_depth(rest, [token | acc], depth - 1)
  end

  # Skip else at non-zero depth
  defp collect_until_else_or_end_at_depth([{tag, [:else]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] and
              depth > 0 do
    collect_until_else_or_end_at_depth(rest, [token | acc], depth)
  end

  defp collect_until_else_or_end_at_depth([token | rest], acc, depth) do
    collect_until_else_or_end_at_depth(rest, [token | acc], depth)
  end

  # Collect tokens until end at depth 0
  defp collect_until_end_at_depth([], acc, _depth), do: {Enum.reverse(acc), []}

  defp collect_until_end_at_depth([{tag, [:end]} | rest], acc, 0)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    {Enum.reverse(acc), rest}
  end

  # Increase depth on if/range/with
  defp collect_until_end_at_depth([{tag, [:if | _]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    collect_until_end_at_depth(rest, [token | acc], depth + 1)
  end

  defp collect_until_end_at_depth([{tag, [:range | _]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    collect_until_end_at_depth(rest, [token | acc], depth + 1)
  end

  defp collect_until_end_at_depth([{tag, [:with | _]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] do
    collect_until_end_at_depth(rest, [token | acc], depth + 1)
  end

  # Decrease depth on end (when depth > 0)
  defp collect_until_end_at_depth([{tag, [:end]} = token | rest], acc, depth)
       when tag in [:action, :action_trim_left, :action_trim_right, :action_trim_both] and
              depth > 0 do
    collect_until_end_at_depth(rest, [token | acc], depth - 1)
  end

  defp collect_until_end_at_depth([token | rest], acc, depth) do
    collect_until_end_at_depth(rest, [token | acc], depth)
  end

  # Evaluate an expression (list of pipeline stages)
  defp eval_expression([{:expr, stages}], ctx), do: eval_expression(stages, ctx)

  defp eval_expression(stages, ctx) when is_list(stages) do
    Enum.reduce(stages, nil, fn stage, acc ->
      case stage do
        {:field, path} ->
          resolve_field(path, ctx)

        {:string, str} ->
          str

        {:integer, num} ->
          num

        {:call, [func_name | args]} ->
          arg_values = Enum.map(args, &eval_expression([&1], ctx))
          piped_args = if acc, do: [acc | arg_values], else: arg_values
          call_function(func_name, piped_args, ctx)

        other ->
          Logger.warning("Unknown stage: #{inspect(other)}")
          acc
      end
    end)
  end

  defp eval_expression(other, _ctx) do
    Logger.warning("Unknown expression: #{inspect(other)}")
    nil
  end

  # Resolve field path
  # When path is empty (just "." in the template), return the dot value if in a range/with context
  defp resolve_field([], ctx), do: Map.get(ctx, :dot, ctx)
  defp resolve_field([""], ctx), do: Map.get(ctx, :dot, ctx)

  defp resolve_field(["Keywords"], ctx) do
    value = ctx[:keywords]
    Logger.debug("Resolved field .Keywords => #{inspect(value)}")
    value
  end

  defp resolve_field(["Config", key], ctx) do
    value = get_config_value(ctx, key)
    Logger.debug("Resolved field .Config.#{key} => #{inspect(value)}")
    value
  end

  defp resolve_field(["Query", key], ctx) do
    value = get_query_value(ctx, key)
    Logger.debug("Resolved field .Query.#{key} => #{inspect(value)}")
    value
  end

  defp resolve_field(["Result", key], ctx) do
    # Access previously extracted field values
    # The result context is stored under :result key
    result = ctx[:result] || %{}

    value =
      Map.get(result, key) ||
        try do
          Map.get(result, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end

    Logger.debug("Resolved field .Result.#{key} => #{inspect(value)}")
    value
  end

  defp resolve_field(["Categories"], ctx) do
    value = ctx[:categories] || []
    Logger.debug("Resolved field .Categories => #{inspect(value)}")
    value
  end

  defp resolve_field(["Today", "Year"], _ctx) do
    value = Date.utc_today().year
    Logger.debug("Resolved field .Today.Year => #{inspect(value)}")
    value
  end

  defp resolve_field(["True"], _ctx), do: true
  defp resolve_field(["False"], _ctx), do: false

  defp resolve_field([key], ctx) do
    # First check if we're in a with/range context and the dot value has this key
    dot_value = Map.get(ctx, :dot)

    # If we have a dot value that's a map, try to get the key from it first
    value =
      if is_map(dot_value) do
        Map.get(dot_value, key) ||
          Map.get(dot_value, String.downcase(key)) ||
          try do
            Map.get(dot_value, String.to_existing_atom(key)) ||
              Map.get(dot_value, String.downcase(key) |> String.to_existing_atom())
          rescue
            ArgumentError -> nil
          end
      else
        # Fall back to context lookup
        nil
      end

    # If not found in dot, try direct context lookup
    value =
      if is_nil(value) do
        try do
          atom_key = String.downcase(key) |> String.to_existing_atom()
          Map.get(ctx, atom_key)
        rescue
          ArgumentError -> nil
        end
      else
        value
      end

    # If still not found and we have a root context (inside range/with),
    # try resolving from root ($ variable support)
    value =
      if is_nil(value) do
        case Map.get(ctx, :root) do
          root when is_map(root) and root != ctx ->
            resolve_field([key], Map.delete(root, :root))

          _ ->
            nil
        end
      else
        value
      end

    Logger.debug("Resolved field .#{key} => #{inspect(value)}")
    value
  end

  defp resolve_field(path, ctx) when is_map(ctx) do
    # Generic nested field access
    result =
      Enum.reduce_while(path, ctx, fn key, current ->
        value =
          case current do
            %{} ->
              Map.get(current, key) ||
                try do
                  Map.get(current, String.to_existing_atom(key))
                rescue
                  ArgumentError -> nil
                end

            _ ->
              nil
          end

        if value, do: {:cont, value}, else: {:halt, nil}
      end)

    Logger.debug("Resolved field path .#{Enum.join(path, ".")} => #{inspect(result)}")
    result
  end

  defp resolve_field(path, _ctx) do
    Logger.debug("Failed to resolve field path .#{inspect(path)}: context is not a map")
    nil
  end

  # Get config value
  defp get_config_value(context, key) do
    config = context[:config] || %{}
    settings = context[:settings] || []

    value =
      Map.get(config, key) ||
        try do
          Map.get(config, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end

    if is_nil(value) do
      setting = Enum.find(settings, fn s -> s[:name] == key end)
      if setting, do: setting[:default], else: nil
    else
      value
    end
  end

  # Get query value
  defp get_query_value(context, key) do
    query = context[:query] || %{}

    case key do
      "Series" ->
        query[:series] || context[:keywords]

      "Season" ->
        query[:season]

      "Ep" ->
        query[:episode]

      "Episode" ->
        query[:episode]

      "IMDB" ->
        query[:imdb_id]

      "IMDBIDShort" ->
        query[:imdb_id] && String.replace(query[:imdb_id], "tt", "")

      "TMDB" ->
        query[:tmdb_id]

      "TMDBID" ->
        query[:tmdb_id]

      "TVDB" ->
        query[:tvdb_id]

      "TVDBID" ->
        query[:tvdb_id]

      "Album" ->
        query[:album]

      "Artist" ->
        query[:artist]

      "Label" ->
        query[:label]

      "Track" ->
        query[:track]

      "Year" ->
        query[:year]

      "Genre" ->
        query[:genre]

      _ ->
        atom_key = String.downcase(key) |> String.to_existing_atom()
        Map.get(query, atom_key)
    end
  rescue
    ArgumentError -> nil
  end

  # Call functions
  defp call_function("or", args, _ctx) do
    Enum.find(args, "", fn arg -> if truthy?(arg), do: arg end)
  end

  defp call_function("and", args, _ctx) do
    if Enum.all?(args, &truthy?/1), do: List.last(args), else: false
  end

  defp call_function("not", [arg], _ctx), do: !truthy?(arg)
  defp call_function("eq", [a, b], _ctx), do: a == b
  defp call_function("ne", [a, b], _ctx), do: a != b
  defp call_function("lt", [a, b], _ctx) when is_number(a) and is_number(b), do: a < b
  defp call_function("le", [a, b], _ctx) when is_number(a) and is_number(b), do: a <= b
  defp call_function("gt", [a, b], _ctx) when is_number(a) and is_number(b), do: a > b
  defp call_function("ge", [a, b], _ctx) when is_number(a) and is_number(b), do: a >= b

  defp call_function("len", [arg], _ctx) when is_list(arg), do: length(arg)
  defp call_function("len", [arg], _ctx) when is_binary(arg), do: String.length(arg)
  defp call_function("len", [arg], _ctx) when is_map(arg), do: map_size(arg)
  defp call_function("len", _, _ctx), do: 0

  defp call_function("index", [coll, key], _ctx) when is_map(coll) do
    Map.get(coll, key) || Map.get(coll, to_string(key))
  end

  defp call_function("index", [coll, idx], _ctx) when is_list(coll) and is_integer(idx) do
    Enum.at(coll, idx)
  end

  defp call_function("print", args, _ctx), do: Enum.map_join(args, " ", &to_string/1)

  defp call_function("printf", [fmt | args], _ctx) when is_binary(fmt) do
    # Convert Go-style format specifiers to Erlang style
    # %s -> ~s (strings), %d -> ~B (integers), %v -> ~p (any value)
    erlang_fmt =
      fmt
      |> String.replace("%s", "~s")
      |> String.replace("%d", "~B")
      |> String.replace("%v", "~p")
      |> String.replace("%f", "~f")
      |> String.replace("%%", "~%")

    :io_lib.format(to_charlist(erlang_fmt), args) |> IO.iodata_to_binary()
  rescue
    e ->
      Logger.debug("printf error: #{inspect(e)}, fmt=#{fmt}, args=#{inspect(args)}")
      ""
  end

  defp call_function("println", args, _ctx), do: Enum.map_join(args, " ", &to_string/1) <> "\n"

  # Cardigann-specific functions
  defp call_function("re_replace", [value, pattern, replacement], _ctx) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.replace(regex, to_string(value || ""), replacement)
      {:error, _} -> to_string(value || "")
    end
  end

  defp call_function("join", [collection, delimiter], _ctx) when is_list(collection) do
    Enum.map_join(collection, delimiter, &to_string/1)
  end

  defp call_function("join", [value, _], _ctx), do: to_string(value || "")

  # slice - substring extraction: slice(str, start, end)
  defp call_function("slice", [str, start, stop], _ctx) when is_binary(str) do
    s = if is_binary(start), do: String.to_integer(start), else: start
    e = if is_binary(stop), do: String.to_integer(stop), else: stop
    String.slice(str, s..(e - 1)//1)
  end

  defp call_function("slice", [str, start], _ctx) when is_binary(str) do
    s = if is_binary(start), do: String.to_integer(start), else: start
    String.slice(str, s..-1//1)
  end

  defp call_function("slice", _, _ctx), do: ""

  defp call_function(name, args, _ctx) do
    Logger.warning("Unknown function: #{name}/#{length(args)}")
    ""
  end

  # Truthy check
  defp truthy?(nil), do: false
  defp truthy?(""), do: false
  defp truthy?([]), do: false
  defp truthy?(false), do: false
  defp truthy?(0), do: false
  defp truthy?(v) when is_float(v) and v == 0.0, do: false
  defp truthy?(_), do: true

  # Format output
  defp format_output(nil, _), do: ""
  defp format_output("", _), do: ""
  defp format_output(v, true) when is_binary(v), do: url_encode(v)
  defp format_output(v, false) when is_binary(v), do: v
  defp format_output(v, _) when is_boolean(v), do: to_string(v)
  defp format_output(v, _) when is_number(v), do: to_string(v)
  defp format_output(v, _) when is_list(v), do: Enum.map_join(v, ",", &to_string/1)
  defp format_output(v, url_encode?), do: format_output(to_string(v), url_encode?)

  @doc """
  URL-encodes a string for use in URL paths.
  """
  @spec url_encode(String.t()) :: String.t()
  def url_encode(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> Enum.map_join("", fn char ->
      if unreserved_char?(char), do: <<char>>, else: "%" <> Base.encode16(<<char>>, case: :upper)
    end)
  end

  def url_encode(nil), do: ""
  def url_encode(value), do: url_encode(to_string(value))

  defp unreserved_char?(c) do
    (c >= ?A and c <= ?Z) or (c >= ?a and c <= ?z) or (c >= ?0 and c <= ?9) or
      c in [?-, ?_, ?., ?~]
  end
end
