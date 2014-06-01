defmodule Skills.TwoHandedPolearm do
  use Systems.Skill

  def prereqs, do: []
  def cost,    do: 0.8
  def level,   do: 1

  def help do
    "This is skill with polearms such as halberds."
  end
end