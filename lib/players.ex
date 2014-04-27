defmodule Players do
  use GenServer.Behaviour

  # Public API
  def connected(connection) do
    :gen_server.cast(:players, {:connected, connection})
  end

  def disconnected(connection) do
    player = find_by_connection(connection)
    character = Components.Login.get_character(player)
    if character do
      Components.Online.value(character, false)
      Components.Player.value(character, nil)
    end
    :gen_server.cast(:players, {:disconnected, player})
  end

  def send_message(player, message) do
    :gen_server.cast(:players, {:send_message, player, message})
  end

  def find_by_connection(connection) do
    :gen_server.call(:players, {:find_by_connection, connection})
  end

  def all do
    :gen_server.call(:players, :all)
  end


  # GenServer API
  def start_link() do
    :gen_server.start_link({:local, :players}, __MODULE__, [], [])
  end

  def init([]) do
    {:ok, []}
  end

  def handle_cast({:connected, connection}, players) do
    {:ok, player} = ApathyDrive.Entity.init

    ApathyDrive.Entity.add_component(player, Components.Connection, connection)

    ApathyDrive.Entity.add_component(player, Components.Login, nil)

    Components.Login.intro(player)

    {:noreply, [player | players] }
  end

  def handle_cast({:disconnected, player}, players) do
    {:noreply, List.delete(players, player)}
  end

  def handle_cast({:send_message, player, message}, players) do
    connection = Components.Connection.get_connection(player)
    send connection, ExJSON.generate(message)
    {:noreply, players}
  end

  def handle_call({:find_by_connection, connection}, _from, players) do
    player = Enum.find players, fn (player) ->
      Components.Connection.get_connection(player) == connection
    end
    {:reply, player, players}
  end

  def handle_call(:all, _from, players) do
    {:reply, players, players}
  end

end