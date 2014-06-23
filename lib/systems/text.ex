defmodule Systems.Text do
  use Systems.Reload

  def interpolate(string, user, target \\ nil) do
    string = String.replace(string, ~r/\{\{user\}\}/,   Components.Name.value(user))
    string = String.replace(string, ~r/\{\{target\}\}/, Components.Name.value(target))

    if Entity.has_component?(user, Components.Gender) do
      string = case Components.Gender.value(user) do
                 "male"   ->
                   String.replace(string, ~r/\{\{user:(.+?)\/(.+?)\/(.+?)\}\}/, "\\1")
                 "female" ->
                   String.replace(string, ~r/\{\{user:(.+?)\/(.+?)\/(.+?)\}\}/, "\\2")
                 other ->
                   String.replace(string, ~r/\{\{user:(.+?)\/(.+?)\/(.+?)\}\}/, "\\3")
               end
    else
      string = String.replace(string, ~r/\{\{user:(.+?)\/(.+?)\/(.+?)\}\}/, "\\3")
    end

    if target && Entity.has_component?(target, Components.Gender) do
      string = case Components.Gender.value(target) do
                 "male"   ->
                   String.replace(string, ~r/\{\{target:(.+?)\/(.+?)\/(.+?)\}\}/, "\\1")
                 "female" ->
                   String.replace(string, ~r/\{\{target:(.+?)\/(.+?)\/(.+?)\}\}/, "\\2")
                 other ->
                   String.replace(string, ~r/\{\{target:(.+?)\/(.+?)\/(.+?)\}\}/, "\\3")
               end
    else
      string = String.replace(string, ~r/\{\{target:(.+?)\/(.+?)\/(.+?)\}\}/, "\\3")
    end
    string
  end

end