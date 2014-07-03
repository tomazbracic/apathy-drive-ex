defmodule Components.Connection do
  use Systems.Reload
  use GenEvent

  ### Public API
  def value(nil) do
    nil
  end

  def value(entity) do
    GenEvent.call(entity, Components.Connection, :get_connection)
  end

  def get_connection(entity) do
    value(entity)
  end

  def serialize(_entity) do
    nil
  end

  ### GenEvent API
  def init(connection_pid) do
    {:ok, connection_pid}
  end

  def handle_call(:get_connection, connection_pid) do
    {:ok, connection_pid, connection_pid}
  end

  def handle_event(_, current_value) do
    {:ok, current_value}
  end
end