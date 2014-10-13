defmodule Systems.Match do
  use Systems.Reload

  def all(pids, :match_name, string) do
    Enum.filter(pids, &(match_name(string, &1)))
  end

  def all(pids, :match_keyword, string) do
    case all(pids, :match_name, string) do
      []    -> Enum.filter(pids, &(match_keyword(string, &1)))
      value -> value
    end
  end

  def all(pids, :keyword_starts_with, string) do
    case all(pids, :match_keyword, string) do
      []    -> Enum.filter(pids, &(keyword_starts_with(string, &1)))
      value -> value
    end
  end

  def all(pids, :name_contains, string) do
    case all(pids, :keyword_starts_with, string) do
      []    -> Enum.filter(pids, &(name_contains(string, &1)))
      value -> value
    end
  end

  def one(pids, match_level, string) do
    {string, number} = string_number(string)
    one(pids, match_level, string, number)
  end

  def one(pids, match_level, string, number) do
    all(pids, match_level, string)
    |> Enum.at(number)
  end

  def match_name("", _pid), do: false
  def match_name(string, pid) do
    String.downcase(string) == pid
                               |> Components.Name.value
                               |> String.downcase
  end

  def match_keyword("", _pid), do: false
  def match_keyword(string, pid) do
    if pid |> Entity.list_components |> Enum.member?(Components.Keywords) do
      pid |> Components.Keywords.value
          |> Enum.any?(fn (keyword) ->
               String.downcase(string) == String.downcase(keyword)
             end)
    else
      false
    end
  end

  def keyword_starts_with("", _pid), do: false
  def keyword_starts_with(string, pid) do
    if pid |> Entity.list_components |> Enum.member?(Components.Keywords) do
      pid |> Components.Keywords.value
          |> Enum.any?(fn (keyword) ->
               String.downcase(keyword) |> String.starts_with?(string |> String.downcase)
             end)
    else
      false
    end
  end

  def name_contains("", _pid), do: false
  def name_contains(string, pid) do
    pid |> Components.Name.value
        |> String.downcase
        |> String.contains?(string |> String.downcase)
  end

  def string_number(string) do
    number = extract_number(Regex.run(~r/\d+$/, string))
    string = remove_number_from_string(string, number)
    number = indexify_number(number)
    {string, number}
  end

  def extract_number([number]), do: number
  def extract_number(nil),      do: nil

  def remove_number_from_string(string, nil), do: string
  def remove_number_from_string(string, number) do
    String.replace(string, " #{number}", "")
  end

  def indexify_number(nil), do: 0
  def indexify_number(number) do
    number
    |> String.to_integer
    |> -(1)
    |> max(0)
  end

end
