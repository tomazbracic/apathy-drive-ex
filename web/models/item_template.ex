defmodule ItemTemplate do
  use Ecto.Model
  use Systems.Reload
  use GenServer
  alias ApathyDrive.Repo
  alias Phoenix.PubSub

  schema "item_templates" do
    field :name,                  :string
    field :keywords,              {:array, :string}, default: []
    field :description,           :string
    field :worn_on,               :string
    field :hit_verbs,             {:array, :string}, default: []
    field :damage,                ApathyDrive.JSONB
    field :required_skills,       ApathyDrive.JSONB
    field :speed,                 :float
    field :accuracy_skill,        :string
    field :ac,                    :integer
    field :uses,                  :integer
    field :destruct_message,      :string
    field :room_destruct_message, :string
    field :can_pick_up,           :boolean
    field :cost,                  :integer
    field :light,                 :integer
    field :always_lit,            :boolean

    timestamps
  end

  def value(item_template) do
    GenServer.call(item_template, :value)
  end

  def find(id) do
    case :global.whereis_name(:"item_template_#{id}") do
      :undefined ->
        load(id)
      item_template ->
        item_template
    end
  end

  def load(id) do
    case Repo.get(ItemTemplate, id) do
      %ItemTemplate{} = item_template ->

        {:ok, pid} = Supervisor.start_child(ApathyDrive.Supervisor, {:"item_template_#{id}", {GenServer, :start_link, [ItemTemplate, item_template, [name: {:global, :"item_template_#{id}"}]]}, :permanent, 5000, :worker, [ItemTemplate]})

        PubSub.subscribe(pid, "item_templates")

        pid
      nil ->
        nil
    end
  end

  def spawn_item(item_template_id, %Monster{} = monster) when is_integer(item_template_id) do
    item_template_id
    |> find
    |> spawn_item(monster)
  end

  def spawn_item(item_template, %Monster{} = monster) do
    GenServer.call(item_template, :spawn_item)
    |> Item.to_monster_inventory(monster)
  end

  def spawn_item(item_template, %Room{} = room) do
    GenServer.call(item_template, :spawn_item)
    |> Item.to_room(room)
  end

  def skill_too_low?(%Monster{} = monster, %{required_skills: nil}), do: false
  def skill_too_low?(%Monster{} = monster, %{required_skills: %{} = required_skills}) do
    skill = required_skills
            |> Map.keys
            |> Enum.find(fn(skill) ->
                 Monster.modified_skill(monster, skill) < required_skills[skill]
               end)

    if skill do
      {skill, required_skills[skill]}
    end
  end

  # Generate functions from Ecto schema
  fields = Keyword.keys(@struct_fields) -- Keyword.keys(@ecto_assocs)

  Enum.each(fields, fn(field) ->
    def unquote(field)(item_template) do
      GenServer.call(item_template, unquote(field))
    end
  end)

  Enum.each(fields, fn(field) ->
    def handle_call(unquote(field), _from, item_template) do
      {:reply, Map.get(item_template, unquote(field)), item_template}
    end
  end)

  def handle_call(:spawn_item, _from, item_template) do
    values = item_template
             |> Map.from_struct
             |> Enum.into(Keyword.new)

    item = struct(Item, values)
           |> Map.put(:item_template_id, item_template.id)
           |> Map.put(:id, nil)
           |> Item.insert

    worker_id = :"item_#{item.id}"

    {:ok, pid} = Supervisor.start_child(ApathyDrive.Supervisor, {worker_id, {GenServer, :start_link, [Item, item, []]}, :transient, 5000, :worker, [Item]})

    if item_template.always_lit do
      Item.light(pid)
    end

    {:reply, pid, item_template}
  end

  def handle_call(:value, _from, item_template) do
    {:reply, item_template, item_template}
  end
end
