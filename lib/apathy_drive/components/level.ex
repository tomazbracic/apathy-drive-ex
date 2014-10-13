defmodule Components.Level do
  use Systems.Reload
  use GenEvent

  ### Public API
  def value(entity) do
    GenEvent.call(entity, Components.Level, :value)
  end

  def value(entity, new_value) do
    GenEvent.notify(entity, {:set_level, new_value})
  end

  def advance(entity) do
    GenEvent.notify(entity, {:add_level, 1})
  end

  def serialize(entity) do
    %{"Level" => value(entity)}
  end

  ### GenEvent API
  def init(value) do
    {:ok, value}
  end

  def handle_call(:value, value) do
    {:ok, value, value}
  end

  def handle_event({:set_level, new_value}, _value) do
    {:ok, new_value }
  end

  def handle_event({:add_level, amount}, value) do
    {:ok, value + amount }
  end

  def handle_event(_, current_value) do
    {:ok, current_value}
  end
end
