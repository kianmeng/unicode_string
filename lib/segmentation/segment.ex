defmodule Unicode.String.Segment do
  @moduledoc false

  import SweetXml
  require Unicode.Set

  # This is the formal definition but it takes a while to compile
  # and all of the known variable names are in the Latin-1 set
  # defguard is_id_start(char) when Unicode.Set.match?(char, "\\p{ID_start}")
  # defguard is_id_continue(char) when Unicode.Set.match?(char, "\\p{ID_continue}")

  defguard is_id_start(char)
    when char in ?A..?Z

  defguard is_id_continue(char)
    when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_

  def locales do
    locale_map()
    |> Map.keys
  end

  def rules(locale, segment_type) do
    with {:ok, segment} <- segments(locale, segment_type) do
      variables = Map.fetch!(segment, :variables) |> expand_variables()
      rules = Map.fetch!(segment, :rules)

      rules
      |> expand_rules(variables)
      |> compile_rules
      |> wrap(:ok)
    end
  end

  def rules!(locale, segment_type) do
    case rules(locale, segment_type) do
      {:ok, rules} -> rules
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def suppressions(locale, segment_type) do
    with {:ok, segment} <- segments(locale, segment_type) do
      {:ok, Map.fetch!(segment, :suppressions)}
    end
  end

  def suppressions!(locale, segment_type) do
    case suppressions(locale, segment_type) do
      {:ok, suppressions} -> suppressions
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # These options set unicode mode. Interpreset certain
  # codes like \B and \w in the unicode space, ignore
  # unescaped whitespace in regexs
  @regex_options [:unicode, :anchored, :extended, :ucp]
  @rule_splitter ~r/[×÷]/u

  defp compile_rules(rules) do
    Enum.map(rules, fn {sequence, rule} ->
      [left, operator, right] = Regex.split(@rule_splitter, rule, include_captures: true)
      operator = if operator == "×", do: :no_break, else: :break
      {sequence, {operator, compile_regex!(left), compile_regex!(right)}}
    end)
  end

  defp compile_regex!("") do
    :any
  end

  defp compile_regex!(string) do
    string
    |> String.trim
    |> Unicode.Regex.compile!(@regex_options)
  end

  def evaluate_rules(string, rules) do
    Enum.reduce_while(rules, [], fn rule, _acc ->
      {_sequence, {operator, _fore, _aft}} = rule
      case evaluate_rule(string, rule) do
        {:pass, result} -> {:halt, {:pass, operator, result}}
        {:fail, result} -> {:cont, {:fail, operator, result}}
      end
    end)
    |> return_break_or_no_break
  end

  # The final implicit rule is to
  # to break. ie: :any ÷ :any
  defp return_break_or_no_break({:fail, _, string}) do
    << char :: utf8, rest :: binary >> = string
    {:break, [<< char >>, rest]}
  end

  defp return_break_or_no_break({:pass, operator, result}) do
    {operator, result}
  end

  defp evaluate_rule(string, {_seq, {_operator, :any, aft}}) do
    << char :: utf8, rest :: binary >> = string
    if Regex.match?(aft, rest) do
      {:pass, [<< char >>, rest]}
    else
      {:fail, string}
    end
  end

  defp evaluate_rule(string, {_seq, {_operator, fore, :any}}) do
    case Regex.split(fore, string, parts: 2, include_captures: true, trim: true) do
      [match, rest] ->
        {:pass, [match, rest]}
      [_other] ->
        {:fail, string}
    end
  end

  defp evaluate_rule(string, {_seq, {_operator, fore, aft}}) do
    case Regex.split(fore, string, parts: 2, include_captures: true, trim: true) do
      [match, rest] ->
        if Regex.match?(aft, rest), do: {:pass, [match, rest]}, else: {:fail, string}
      [_other] ->
        {:fail, string}
    end
  end

  @doc false
  def get_rule(rule, locale, type) when is_float(rule) do
    with {:ok, rules} <- rules(locale, type) do
      Enum.find(rules, &(elem(&1, 0) == rule))
    end
  end

  defp expand_rules(rules, variables) do
    Enum.reduce(rules, [], fn %{name: sequence, value: rule}, acc ->
      rule =
        rule
        |> String.trim
        |> substitute_variables(variables)

      [{sequence, rule} | acc]
    end)
    |> Enum.sort
  end

  defp expand_variables(variable_list) do
    Enum.reduce variable_list, %{}, fn
      %{name: << "$", name :: binary >>, value: value}, variables ->
        new_value = substitute_variables(value, variables)
        Map.put(variables, name, new_value)
    end
  end

  defp substitute_variables("", _variables) do
    ""
  end

  defp substitute_variables(<< "$", char :: utf8, rest :: binary >>, variables)
      when is_id_start(char) do
    {name, rest} = extract_variable_name(<< char >> <> rest)
    Map.fetch!(variables, name) <> substitute_variables(rest, variables)
  end

  defp substitute_variables(<< char :: binary-1, rest :: binary >>, variables) do
    char <> substitute_variables(rest, variables)
  end

  defp extract_variable_name("" = string) do
    {string, ""}
  end

  defp extract_variable_name(<< char :: utf8, rest :: binary >>)
       when is_id_continue(char) do
    {string, rest} = extract_variable_name(rest)
    {<< char >> <> string, rest}
  end

  defp extract_variable_name(rest) do
    {"", rest}
  end

  @app_name Mix.Project.config[:app]
  @segments_dir Path.join(:code.priv_dir(@app_name), "/segments")

  @doctype "<!DOCTYPE ldml SYSTEM \"../../common/dtd/ldml.dtd\">"

  defp locale_map do
    @segments_dir
    |> File.ls!()
    |> Enum.map(fn locale_file ->
      locale =
        locale_file
        |> String.split(".xml")
        |> hd
        |> String.replace("_", "-")

      {locale, locale_file}
    end)
    |> Map.new
  end

  def ancestors(locale_name) do
    if Map.get(locale_map(), locale_name) do
      case String.split(locale_name, "-") do
        [locale] -> [locale, "root"]
        [locale, _territory] -> [locale_name, locale, "root"]
        [locale, script, _territory] -> [locale_name, "#{locale}-#{script}", locale, "root"]
      end
      |> wrap(:ok)
    else
      {:error, unknown_locale_error(locale_name)}
    end
  end

  def merge_ancestors("root") do
    raw_segments!("root")
    |> wrap(:ok)
  end

  def merge_ancestors(locale) when is_binary(locale) do
    with {:ok, ancestors} <- ancestors(locale) do
      merge_ancestors(ancestors)
      |> wrap(:ok)
    end
  end

  def merge_ancestors([locale, root]) do
    merge_ancestor(locale, raw_segments!(root))
  end

  def merge_ancestors([locale | rest]) do
    merge_ancestor(locale, merge_ancestors(rest))
  end

  # For each segement type, add the variables, rules and
  # suppressions from locale to other
  defp merge_ancestor(locale, other) do
    locale_segments = raw_segments!(locale)

    Enum.map(other, fn {segment_type, content} ->
      variables = Map.fetch!(content, :variables) ++
        (get_in(locale_segments, [segment_type, :variables]) || [])
      rules = Map.fetch!(content, :rules) ++
        (get_in(locale_segments, [segment_type, :rules]) || [])
      suppressions = Map.fetch!(content, :suppressions) ++
        (get_in(locale_segments, [segment_type, :suppressions]) || [])
      {segment_type, %{content | variables: variables, rules: rules, suppressions: suppressions}}
    end)
    |> Map.new
  end

  defp raw_segments(locale) do
    if file = Map.get(locale_map(), locale) do
      content =
        @segments_dir
        |> Path.join(file)
        |> File.read!()
        |> String.replace(@doctype, "")
        |> xpath(~x"//segmentation"l,
          type: ~x"./@type"s,
          variables: [
             ~x".//variable"l,
             name: ~x"./@id"s,
             value: ~x"./text()"s
          ],
          rules: [
            ~x".//rule"l,
             name: ~x"./@id"f,
             value: ~x"./text()"s
          ],
          suppressions: ~x".//suppression/text()"ls
        )

      Enum.map(content, fn c ->
        type = c.type
        |> Macro.underscore()
        |> String.replace("__", "_")
        |> String.to_atom

        {type, %{rules: c.rules, variables: c.variables, suppressions: c.suppressions}}
      end)
      |> Map.new
      |> wrap(:ok)
    else
      {:error, unknown_locale_error(locale)}
    end
  end

  defp raw_segments!(locale) do
    case raw_segments(locale) do
      {:ok, segments} -> segments
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc false
  def segments(locale) do
    merge_ancestors(locale)
  end

  @doc false
  def segments(locale, segment_type) when is_binary(locale) do
    with {:ok, segments} <- segments(locale) do
      if segment = Map.get(segments, segment_type) do
        {:ok, segment}
      else
        {:error, unknown_segment_type_error(segment_type)}
      end
    end
  end

  defp wrap(term, atom) do
    {atom, term}
  end

  @doc false
  def unknown_locale_error(locale) do
    "Unknown locale #{inspect locale}"
  end

  @doc false
  def unknown_segment_type_error(segment_type) do
    "Unknown segment type #{inspect segment_type}"
  end
end