defmodule ApathyDrive.Character do
  use Ecto.Schema
  use ApathyDrive.Web, :model
  alias ApathyDrive.{Ability, AbilityDamageType, AbilityTrait, Character, CharacterSkill,
                     CharacterReputation, Companion, Item, Level,  Monster, Mobile, Party, Race,
                     RaceTrait, Reputation, Room, RoomServer, Skill, Text, TimerManager}

  require Logger
  import Comeonin.Bcrypt

  @behaviour Access
  defdelegate get_and_update(container, key, fun), to: Map
  defdelegate fetch(container, key), to: Map
  defdelegate get(container, key, default), to: Map
  defdelegate pop(container, key), to: Map

  schema "characters" do
    field :name,            :string
    field :gender,          :string
    field :email,           :string
    field :password,        :string
    field :experience,      :integer, default: 0
    field :level,           :integer, default: 1
    field :timers,          :map, virtual: true, default: %{}
    field :admin,           :boolean
    field :flags,           :map, default: %{}
    field :gold,            :integer, default: 150
    field :race_id,         :integer
    field :pity_modifier,   :integer, default: 0
    field :race,            :string, virtual: true
    field :monitor_ref,     :any, virtual: true
    field :ref,             :any, virtual: true
    field :socket,          :any, virtual: true
    field :effects,         :map, virtual: true, default: %{}
    field :last_effect_key, :integer, virtual: true, default: 0
    field :hp,              :float, virtual: true, default: 1.0
    field :mana,            :float, virtual: true, default: 1.0
    field :abilities,       :map, virtual: true, default: %{}
    field :inventory,       :any, virtual: true, default: []
    field :equipment,       :any, virtual: true, default: []
    field :ability_shift,   :float, virtual: true
    field :ability_special, :float, virtual: true
    field :attack_target,   :any, virtual: true
    field :strength,        :integer, virtual: true
    field :agility,         :integer, virtual: true
    field :intellect,       :integer, virtual: true
    field :willpower,       :integer, virtual: true
    field :health,          :integer, virtual: true
    field :charm,           :integer, virtual: true
    field :leader,          :any, virtual: true
    field :invitees,        :any, virtual: true, default: []
    field :reputations,     :map, virtual: true, default: %{}
    field :skills,          :map, virtual: true, default: %{}
    field :editing,         :any, virtual: true

    belongs_to :room, Room

    has_many :items_instances, ApathyDrive.ItemInstance
    has_many :characters_reputations, ApathyDrive.CharacterReputation

    has_many :characters_skills, ApathyDrive.CharacterSkill
    has_many :trained_skills, through: [:characters_skills, :skill]

    timestamps()
  end

  def companion(%Character{id: id}, %Room{} = room) do
    room.mobiles
    |> Map.values
    |> Enum.find(& Map.get(&1, :character_id) == id)
  end

  def changeset(character, params \\ %{}) do
    character
    |> cast(params, ~w(name race_id gender))
    |> validate_required(~w(name race_id gender)a)
    |> validate_inclusion(:race_id, ApathyDrive.Race.ids)
    |> validate_inclusion(:gender, ["male", "female"])
    |> validate_format(:name, ~r/^[a-zA-Z]+$/)
    |> unique_constraint(:name, name: :characters_lower_name_index, on: Repo)
    |> validate_length(:name, min: 1, max: 12)
  end

  def sign_up_changeset(character, params \\ %{}) do
    character
    |> cast(params, ~w(email password))
    |> validate_required(~w(email password)a)
    |> validate_format(:email, ~r/@/)
    |> validate_length(:email, min: 3, max: 100)
    |> validate_length(:password, min: 6)
    |> unique_constraint(:email, name: :characters_lower_email_index, on: Repo)
    |> validate_confirmation(:password)
  end

  def load_abilities(%Character{} = character) do
    character =
      character
      |> Repo.preload([:characters_skills, :trained_skills], force: true)
      |> Map.put(:abilities, %{})
      |> Map.put(:skills, %{})

    Enum.reduce(character.characters_skills, character, fn (character_skill, character) ->
      skill =
        character_skill.skill
        |> Map.put(:experience, character_skill.experience)
        |> Skill.set_level

      skill_abilities =
        ApathyDrive.SkillAbility
        |> Ecto.Query.where([ss], ss.skill_id == ^skill.id and ss.level <= ^skill.level)
        |> Ecto.Query.preload([:ability])
        |> Repo.all

      character =
        Enum.reduce(skill_abilities, character, fn
          %{ability: %Ability{id: id, kind: "passive"}}, character ->
            case AbilityTrait.load_traits(id) do
              %{"GrantSkill" => skill_name} = effect ->
                if character.skills[skill_name] && character.skills[skill_name].level > skill.level do
                  Systems.Effect.add(character, effect)
                else
                  character.skills
                  |> update_in(&Map.put(&1, skill_name, %Skill{name: skill_name, level: skill.level}))
                  |> Systems.Effect.add(effect)
                end
              %{} = effect ->
                Systems.Effect.add(character, effect)
            end

          %{level: level, ability: %Ability{id: id} = ability}, character ->
            ability =
              put_in(ability.traits, AbilityTrait.load_traits(id))
              |> Map.put(:level, level)

            ability =
              case AbilityDamageType.load_damage(id) do
                [] ->
                  ability
                damage ->
                  update_in(ability.traits, &(Map.put(&1, "Damage", damage)))
              end
            update_in(character.abilities, fn abilities ->
              Map.put(abilities, ability.command, ability)
            end)
        end)

      character.skills
      |> update_in(&Map.put(&1, character_skill.skill.name, skill))
    end)
  end

  def load_race(%Character{race_id: race_id} = character) do
    race = Repo.get(Race, race_id)

    effect =
      RaceTrait.load_traits(race_id)
      |> Map.put("stack_key", "race")

    attributes =
      Map.take(race, [:strength, :agility, :intellect, :willpower, :health, :charm])

    character
    |> Map.put(:race, race.name)
    |> Map.merge(attributes)
    |> Systems.Effect.add(effect)
  end

  def load_reputations(%Character{} = character) do
    reputations =
      character
      |> Ecto.assoc([:characters_reputations])
      |> Ecto.Query.preload([:area])
      |> Repo.all
      |> Enum.reduce(%{}, &(Map.put(&2, &1.area.id, %{name: &1.area.name, reputation: &1.reputation})))

    Map.put(character, :reputations, reputations)
  end

  def load_items(%Character{} = character) do
    items = ApathyDrive.ItemInstance.load_items(character)

    character
    |> Map.put(:inventory, Enum.reject(items, &(&1.equipped)))
    |> Map.put(:equipment, Enum.filter(items, &(&1.equipped)))
  end

  def sanitize(message) do
    {:safe, message} = Phoenix.HTML.html_escape(message)

    message
  end

  def weapon(%Character{} = character) do
    character.equipment
    |> Enum.find(&(&1.worn_on in ["Weapon Hand", "Two Handed"]))
  end

  def sign_in(email, password) do
    player = Repo.get_by(Character, email: email)
    sign_in?(player, password) && player
  end

  def sign_in?(%Character{password: stored_hash}, password) do
    checkpw(password, stored_hash)
  end

  def sign_in?(nil, _password) do
    dummy_checkpw()
  end

  def add_experience(%Character{level: level} = character, exp) do
    character =
      character
      |> Map.put(:experience, character.experience + exp)
      |> ApathyDrive.Level.advance

    %Character{id: character.id}
    |> Ecto.Changeset.change(%{experience: character.experience})
    |> Repo.update!

    if character.level > level do
      Mobile.send_scroll character, "<p>You ascend to level #{character.level}!"

      send(character.socket, {:update_character, %{room_id: character.room_id, power: Mobile.power_at_level(character, character.level), level: character.level}})

      %Character{id: character.id}
      |> Ecto.Changeset.change(%{level: character.level})
      |> Repo.update!
    end

    if character.level < level do
      Mobile.send_scroll character, "<p>You fall to level #{character.level}!"

      send(character.socket, {:update_character, %{room_id: character.room_id, power: Mobile.power_at_level(character, character.level), level: character.level}})

      %Character{id: character.id}
      |> Ecto.Changeset.change(%{level: character.level})
      |> Repo.update!
    end

    character
  end

  def add_reputation(%Character{} = character, reputations) do
    Enum.reduce(reputations, character, fn %{area_id: area_id, area_name: area_name, reputation: reputation}, character ->
      change = -(reputation / 100)

      character = update_in(character.reputations[area_id], &(&1 || %{name: area_name, reputation: 0.0}))

      current = Reputation.word_for_value(character.reputations[area_id].reputation)

      character = update_in(character.reputations[area_id].reputation, &(max(-1000.0, min(&1 + change, 1000.0))))

      updated = Reputation.word_for_value(character.reputations[area_id].reputation)

      if current != updated do
        Mobile.send_scroll(character, "<p>Your reputation with #{area_name} is now <span class='#{Reputation.color(updated)}'>#{updated}</span>.</p>")
      end

      Repo.insert(%CharacterReputation{character_id: character.id, area_id: area_id, reputation: character.reputations[area_id].reputation}, on_conflict: :replace_all, conflict_target: [:character_id, :area_id])

      character
    end)
  end

  def train_skill(%Character{} = character, %Skill{} = skill, amount) when amount > 0 do
    skill = Repo.preload(skill, :incompatible_skills)
    incompatible_skills = Enum.map(skill.incompatible_skills, & &1.name)

    Repo.insert(%CharacterSkill{character_id: character.id, skill_id: skill.id, experience: skill.experience + amount}, on_conflict: :replace_all, conflict_target: [:character_id, :skill_id])

    old_abilities = Map.values(character.abilities)

    character = load_abilities(character)

    new_abilities = Map.values(character.abilities)

    level = character.skills[skill.name].level

    tnl = Level.exp_to_next_skill_level(level, character.skills[skill.name].experience, skill.training_cost_multiplier)

    tnl =
      if tnl > character.experience do
        "<span class='dark-red'>#{tnl}</span>"
      else
        "<span class='green'>#{tnl}</span>"
      end

    Mobile.send_scroll(character, "<p>You spend #{amount} experience to advance #{skill.name} to level #{level}, it will cost #{tnl} experience to train it any further.</p>")

    Enum.each(new_abilities, fn ability ->
      unless ability in old_abilities do
        Mobile.send_scroll character,  "<p>\nYou've learned the <span class='dark-cyan'>#{ability.name}</span> ability!</p>"
        Mobile.send_scroll character,  "<p>     #{ability.description}</p>"
      end
    end)

    character.skills
    |> Enum.reduce(character, fn {skill_name, %Skill{experience: skill_exp}}, character ->
      if skill_name in incompatible_skills do
        incompatible_skill = Skill.match_by_name(skill_name)
        level = Level.skill_level_at_exp(skill_exp, incompatible_skill.training_cost_multiplier)
        if level > 0 do
          new_level = level - 1
          new_exp = Level.exp_at_level(level, incompatible_skill.training_cost_multiplier)

          Repo.insert(%CharacterSkill{character_id: character.id, skill_id: incompatible_skill.id, experience: new_exp}, on_conflict: :replace_all, conflict_target: [:character_id, :skill_id])

          Mobile.send_scroll(character, "<p>Your #{incompatible_skill.name} skill falls to level #{new_level}.</p>")

          old_abilities = Map.values(character.abilities)

          character = load_abilities(character)

          new_abilities = Map.values(character.abilities)

          Enum.each(old_abilities, fn ability ->
            unless ability in new_abilities do
              Mobile.send_scroll character, "<p>You've forgotten the <span class='dark-cyan'>#{ability.name}</span> ability.</p>"
            end
          end)

          character
        else
          character
        end
      else
        character
      end
    end)
  end

  def prompt(%Character{level: level, hp: hp_percent, mana: mana_percent} = character) do
    max_hp = Mobile.max_hp_at_level(character, level)
    max_mana = Mobile.max_mana_at_level(character, level)
    hp = trunc(max_hp * hp_percent)
    mana = trunc(max_mana * mana_percent)

    if character.editing do
      "[HP=<span class='#{hp_prompt_color(hp_percent)}'>#{hp}</span>/MA=#{mana}] <span class='yellow'>*#{character.editing.name}*</span>:"
    else
      "[HP=<span class='#{hp_prompt_color(hp_percent)}'>#{hp}</span>/MA=#{mana}]:"
    end
  end

  def hp_prompt_color(hp_percent) when hp_percent > 0.5, do: "grey"
  def hp_prompt_color(hp_percent) when hp_percent > 0.2, do: "dark-red"
  def hp_prompt_color(_hp_percent), do: "red"

  def hp_at_level(%Character{} = character, level) do
    max_hp = Mobile.max_hp_at_level(character, level)

    trunc(max_hp * character.hp)
  end

  def mana_at_level(%Character{} = character, level) do
    max_mana = Mobile.max_mana_at_level(character, level)

    trunc(max_mana * character.mana)
  end

  def score_data(%Character{} = character, room) do
    effects =
      character.effects
      |> Map.values
      |> Enum.filter(&(Map.has_key?(&1, "StatusMessage")))
      |> Enum.map(&(&1["StatusMessage"]))

    round_length = Mobile.round_length_in_ms(character)
    dps =
      character
      |> weapon_potency
      |> Enum.reduce(0, fn %{potency: potency} = damage, dps ->
        potency = potency * Mobile.attacks_per_round(character)
        damage = Ability.raw_damage(damage, character, character.level, room) * (potency / 100)
        dps + damage / (round_length / 1000)
      end)

    resistances =
      ApathyDrive.DamageType
      |> Repo.all
      |> Enum.map(& {&1.name, Mobile.ability_value(character, "Resist#{&1.name}")})

    %{
      name: character.name,
      race: character.race,
      level: character.level,
      experience: character.experience,
      perception: Mobile.perception_at_level(character, character.level, room),
      accuracy: Mobile.accuracy_at_level(character, character.level, room),
      spellcasting: Mobile.spellcasting_at_level(character, character.level, room),
      crits: Mobile.crits_at_level(character, character.level, room),
      dodge: Mobile.dodge_at_level(character, character.level, room),
      stealth: Mobile.stealth_at_level(character, character.level, room),
      tracking: Mobile.tracking_at_level(character, character.level, room),
      melee_dps: dps,
      physical_resistance: Mobile.physical_resistance_at_level(character, character.level, nil, room),
      magical_damage: Mobile.magical_damage_at_level(character, character.level, room),
      magical_resistance: Mobile.magical_resistance_at_level(character, character.level, nil, room),
      hp: hp_at_level(character, character.level),
      max_hp: Mobile.max_hp_at_level(character, character.level),
      mana: mana_at_level(character, character.level),
      max_mana: Mobile.max_mana_at_level(character, character.level),
      strength: Mobile.attribute_at_level(character, :strength, character.level),
      agility: Mobile.attribute_at_level(character, :agility, character.level),
      intellect: Mobile.attribute_at_level(character, :intellect, character.level),
      willpower: Mobile.attribute_at_level(character, :willpower, character.level),
      health: Mobile.attribute_at_level(character, :health, character.level),
      charm: Mobile.attribute_at_level(character, :charm, character.level),
      effects: effects,
      item_level: Character.item_level(character),
      resistances: resistances
    }
  end

  def item_level(%Character{equipment: equipment}) do
    equipment
    |> Enum.map(& &1.level)
    |> Enum.sum
  end

  def weapon_potency(character) do
    case Character.weapon(character) do
      nil ->
        [%{potency: 75 / Mobile.attacks_per_round(character), kind: "physical", damage_type: "Normal"}]
      %Item{damage: damage} = item ->
        damage ++ Systems.Effect.effect_list(item, "Damage")
    end
  end

  defimpl ApathyDrive.Mobile, for: Character do

    def ability_value(character, ability) do
      character_value = Systems.Effect.effect_bonus(character, ability)
      equipment_value =
        Enum.reduce(character.equipment, 0, fn item, total ->
          total + Systems.Effect.effect_bonus(item, ability)
        end)
      character_value + equipment_value
    end

    def accuracy_at_level(character, level, room) do
      agi = attribute_at_level(character, :agility, level)
      cha = Party.charm_at_level(room, character, level)
      agi = agi + (cha / 10)
      modifier = ability_value(character, "Accuracy")
      agi * (1 + (modifier / 100))
    end

    def attribute_at_level(%Character{} = character, attribute, level) do
      growth =
        [:strength, :agility, :intellect, :willpower, :health, :charm]
        |> Enum.reduce(0, & &2 + Map.get(character, &1))
        |> div(6)

      base = Map.get(character, attribute)

      base = base + ((growth / 10) * (level - 1))

      from_equipment =
        character.equipment
        |> Enum.reduce(0, fn %Item{} = item, total ->
             skill_name = item.grade
             skill = character.skills[skill_name]
             if skill do
               level = min(character.level, skill.level)
               total + Item.attribute_at_level(item, level, attribute)
              else
               total + Item.attribute_at_level(item, character.level, attribute)
             end
           end)

      (base + from_equipment) / 10
    end

    def attack_interval(character) do
      trunc(round_length_in_ms(character) / attacks_per_round(character))
    end

    def attack_ability(character) do
      case Character.weapon(character) do
        nil ->
          %Ability{
            kind: "attack",
            mana: 0,
            user_message: "You punch {{target}}!",
            target_message: "{{user}} punches you!",
            spectator_message: "{{user}} punches {{target}}!",
            ignores_round_cooldown?: true,
            traits: %{
              "Damage" => Character.weapon_potency(character),
              "Dodgeable" => true,
              "DodgeUserMessage" => "You throw a punch at {{target}}, but they dodge!",
              "DodgeTargetMessage" => "{{user}} throws a punch at you, but you dodge!",
              "DodgeSpectatorMessage" => "{{user}} throws a punch at {{target}}, but they dodge!"
            }
          }
        %Item{name: name, hit_verbs: hit_verbs, miss_verbs: [singular_miss, plural_miss]} ->
          [singular_hit, plural_hit] = Enum.random(hit_verbs)
          %Ability{
            kind: "attack",
            mana: 0,
            user_message: "You #{singular_hit} {{target}} with your #{name}!",
            target_message: "{{user}} #{plural_hit} you with their #{name}!",
            spectator_message: "{{user}} #{plural_hit} {{target}} with their #{name}!",
            ignores_round_cooldown?: true,
            traits: %{
              "Damage" => Character.weapon_potency(character),
              "Dodgeable" => true,
              "DodgeUserMessage" => "You #{singular_miss} {{target}} with your #{name}, but they dodge!",
              "DodgeTargetMessage" => "{{user}} #{plural_miss} you with their #{name}, but you dodge!",
              "DodgeSpectatorMessage" => "{{user}} #{plural_miss} {{target}} with their #{name}, but they dodge!"
            }
          }
      end
    end

    def attacks_per_round(character) do
      case Character.weapon(character) do
        %Item{attacks_per_round: attacks} ->
          attacks
        nil ->
          4
      end
    end

    def auto_attack_target(%Character{attack_target: target} = _character, room, _attack_ability) do
      if room.mobiles[target], do: target
    end

    def caster_level(%Character{level: caster_level}, %{} = _target), do: caster_level

    def cpr(%Character{} = character) do
      time = min(Mobile.round_length_in_ms(character), TimerManager.time_remaining(character, :heartbeat))

      TimerManager.send_after(character, {:heartbeat, time, {:heartbeat, character.ref}})
    end

    def confused(%Character{effects: effects} = character, %Room{} = room) do
      effects
      |> Map.values
      |> Enum.find(fn(effect) ->
           Map.has_key?(effect, "Confusion") && (effect["Confusion"] >= :rand.uniform(100))
         end)
      |> confused(character, room)
    end
    def confused(nil, %Character{}, %Room{}), do: false
    def confused(%{"ConfusionMessage" => message} = effect, %Character{} = character, %Room{} = room) do
      Mobile.send_scroll(character, "<p>#{message}</p>")
      if effect["ConfusionSpectatorMessage"], do: Room.send_scroll(room, "<p>#{Text.interpolate(effect["ConfusionSpectatorMessage"], %{"user" => character})}</p>", [character])
      true
    end
    def confused(%{}, %Character{} = character, %Room{} = room) do
      send_scroll(character, "<p><span class='cyan'>You fumble in confusion!</span></p>")
      Room.send_scroll(room, "<p><span class='cyan'>#{Text.interpolate("{{user}} fumbles in confusion!</span></p>", %{"user" => character})}</span></p>", [character])
      true
    end

    def colored_name(%Character{name: name} = character, %{} = observer) do
      character_level = Mobile.target_level(observer, character)
      observer_level = Mobile.caster_level(observer, character)

      character_power = Mobile.power_at_level(character, character_level)
      observer_power = Mobile.power_at_level(observer, observer_level)

      color =
        cond do
          character_power < (observer_power * 0.66) ->
            "teal"
          character_power < (observer_power * 1.33) ->
            "chartreuse"
          character_power < (observer_power * 1.66) ->
            "blue"
          character_power < (observer_power * 2.00) ->
            "darkmagenta"
          :else ->
            "red"
        end
      "<span style='color: #{color};'>#{name}</span>"
    end

    def crits_at_level(character, level, room) do
      int = attribute_at_level(character, :intellect, level)
      cha = Party.charm_at_level(room, character, level)
      int = int + (cha / 10)
      modifier = ability_value(character, "Crits")
      int * (1 + (modifier / 100))
    end

    def description(%Character{} = character, %Character{} = observer) do
      character_level = Mobile.target_level(observer, character)
      observer_level = Mobile.caster_level(observer, character)

      descriptions =
        [
           strength:  ["puny", "weak", "slightly built", "moderately built", "well built", "muscular", "powerfully built", "heroically proportioned", "Herculean", "physically Godlike"],
           health:    ["frail", "thin", "healthy", "stout", "solid", "massive", "gigantic", "colossal"],
           agility:   ["slowly", "clumsily", "slugishly", "cautiously", "gracefully", "very swiftly", "with uncanny speed", "with catlike agility", "blindingly fast"],
           charm:     ["openly hostile and quite revolting.", "hostile and unappealing.", "quite unfriendly and aloof.", "likeable in an unassuming sort of way.", "quite attractive and pleasant to be around.", "charismatic and outgoing. You can't help but like {{target:him/her/them}}.", "extremely likeable, and fairly radiates charisma.", "incredibly charismatic. You are almost overpowered by {{target:his/her/their}} strong personality.", "overwhelmingly charismatic. You almost drop to your knees in wonder at the sight of {{target:him/her/them}}!"],
           intellect: ["utterly moronic", "quite stupid", "slightly dull", "intelligent", "bright", "extremely clever", "brilliant", "a genius", "all-knowing"],
           willpower: ["selfish and hot-tempered", "sullen and impulsive", "a little naive", "looks fairly knowledgeable", "looks quite experienced and wise", "has a worldly air about {{target:him/her/them}}", "seems to possess a wisdom beyond {{target:his/her/their}} years", "seem to be in an enlightened state of mind", "looks like {{target:he is/she is/they are}} one with the Gods"]
         ]
         |> Enum.reduce(%{}, fn {stat, stat_descriptions}, descriptions ->
              character_stat = Mobile.attribute_at_level(character, stat, character_level)
              observer_stat = Mobile.attribute_at_level(observer, stat, observer_level)

              if character_stat < observer_stat do
                index = trunc((character_stat - observer_stat) / 2) + div(length(stat_descriptions), 2)
                Map.put(descriptions, stat, Enum.at(stat_descriptions, index, Enum.at(stat_descriptions, 0)))
              else
                index = trunc((character_stat - observer_stat) / 2) + div(length(stat_descriptions), 2)
                Map.put(descriptions, stat, Enum.at(stat_descriptions, index, Enum.at(stat_descriptions, -1)))
              end
            end)

      "#{character.name} is a #{descriptions[:health]}, #{descriptions[:strength]} #{character.race}. {{target:He moves/She moves/They move}} #{descriptions[:agility]}, and {{target:is/is/are}} #{descriptions[:charm]} #{character.name} appears to be #{descriptions[:intellect]} and #{descriptions[:willpower]}."
    end

    def die(character, room) do
      character =
        character
        |> Mobile.send_scroll("<p><span class='red'>You have died.</span></p>")
        |> Map.put(:hp, 1.0)
        |> Map.put(:mana, 1.0)
        |> update_in([:effects], fn(effects) ->
             effects
             |> Enum.filter(fn {_key, effect} -> effect["stack_key"] in ["race"] end)
             |> Enum.into(%{})
           end)
        |> Map.put(:timers, %{})
        |> Mobile.update_prompt
        |> Mobile.cpr

      Room.start_room_id
      |> RoomServer.find
      |> RoomServer.mobile_entered(character)

      room =
        character
        |> Character.companion(room)
        |> Companion.dismiss(room)

      put_in(room.mobiles, Map.delete(room.mobiles, character.ref))
      |> Room.send_scroll("<p><span class='red'>#{character.name} has died.</span></p>")
    end

    def dodge_at_level(character, level, room) do
      agi = attribute_at_level(character, :agility, level)
      cha = Party.charm_at_level(room, character, level)
      agi = agi + (cha / 10)
      modifier = ability_value(character, "Dodge")
      agi * (1 + (modifier / 100))
    end

    def enough_mana_for_ability?(character, %Ability{} =  ability) do
      mana = Character.mana_at_level(character, character.level)
      cost = Ability.mana_cost_at_level(ability, character.level)

      mana >= cost
    end

    def enter_message(%Character{name: name}) do
      "<p><span class='yellow'>#{name}</span><span class='dark-green'> walks in from {{direction}}.</span></p>"
    end

    def exit_message(%Character{name: name}) do
      "<p><span class='yellow'>#{name}</span><span class='dark-green'> walks off {{direction}}.</span></p>"
    end

    def has_ability?(%Character{} = character, ability_name) do
      character.effects
      |> Map.values
      |> Enum.map(&Map.keys/1)
      |> List.flatten
      |> Enum.member?(ability_name)
    end

    def heartbeat(%Character{} = character, %Room{} = room) do
      Room.update_mobile(room, character.ref, fn character ->
        character
        |> regenerate_hp_and_mana(room)
        |> TimerManager.send_after({:heartbeat, Mobile.round_length_in_ms(character), {:heartbeat, character.ref}})
      end)
    end

    def held(%{effects: effects} = mobile) do
      effects
      |> Map.values
      |> Enum.find(fn(effect) ->
           Map.has_key?(effect, "held")
         end)
      |> held(mobile)
    end
    def held(nil, %{}), do: false
    def held(%{"effect_message" => message}, %{} = mobile) do
      send_scroll(mobile, "<p>#{message}</p>")
      true
    end

    def hp_description(%Character{hp: hp}) when hp >= 1.0, do: "unwounded"
    def hp_description(%Character{hp: hp}) when hp >= 0.9, do: "slightly wounded"
    def hp_description(%Character{hp: hp}) when hp >= 0.6, do: "moderately wounded"
    def hp_description(%Character{hp: hp}) when hp >= 0.4, do: "heavily wounded"
    def hp_description(%Character{hp: hp}) when hp >= 0.2, do: "severely wounded"
    def hp_description(%Character{hp: hp}) when hp >= 0.1, do: "critically wounded"
    def hp_description(%Character{hp: _hp}), do: "very critically wounded"

    def magical_damage_at_level(character, level, room) do
      damage = attribute_at_level(character, :intellect, level) + (Party.charm_at_level(room, character, level) / 10)
      modifier = ability_value(character, "ModifyDamage") + ability_value(character, "ModifyMagicalDamage")
      damage * (1 + (modifier / 100))
    end

    def magical_resistance_at_level(character, level, damage_type, room) do
      resist = attribute_at_level(character, :willpower, level) + (Party.charm_at_level(room, character, level) / 10)
      mr =
        character.equipment
        |> Enum.reduce(0, fn
             %Item{magical_resistance: magical_resistance}, total ->
               total + (magical_resistance || 0)
             _, total ->
               total
           end)
      modifier = mr + ability_value(character, "MagicalResist") + ability_value(character, "Resist#{damage_type}")
      resist * (modifier / 100)
    end

    def max_hp_at_level(mobile, level) do
      base = trunc(ability_value(mobile, "HPPerHealth") * attribute_at_level(mobile, :health, level))
      modifier = ability_value(mobile, "MaxHP")
      base * (1 + (modifier / 100))
    end

    def max_mana_at_level(mobile, level) do
      base = trunc(max(2, ability_value(mobile, "ManaPerIntellect")) * attribute_at_level(mobile, :intellect, level))
      modifier = ability_value(mobile, "MaxMana")
      base * (1 + (modifier / 100))
    end

    def party_refs(character, room) do
      Party.refs(room, character)
    end

    def perception_at_level(character, level, room) do
      int = attribute_at_level(character, :intellect, level)
      cha = Party.charm_at_level(room, character, level)
      int = int + (cha / 10)
      modifier = ability_value(character, "Perception")
      int * (1 + (modifier / 100))
    end

    def physical_damage_at_level(character, level, room) do
      damage = attribute_at_level(character, :strength, level) + (Party.charm_at_level(room, character, level) / 10)
      modifier = ability_value(character, "ModifyDamage") + ability_value(character, "ModifyPhysicalDamage")
      damage * (1 + (modifier / 100))
    end

    def physical_resistance_at_level(character, level, damage_type, room) do
      resist = attribute_at_level(character, :strength, level) + (Party.charm_at_level(room, character, level) / 10)
      ac =
        character.equipment
        |> Enum.reduce(0, fn
             %Item{physical_resistance: physical_resistance}, total ->
               total + (physical_resistance || 0)
             _, total ->
               total
           end)
      modifier = ac + ability_value(character, "AC") + ability_value(character, "Resist#{damage_type}")
      resist * (modifier / 100)
    end

    def power_at_level(%Character{} = character, level) do
      [:strength, :agility, :intellect, :willpower, :health, :charm]
      |> Enum.reduce(0, & &2 + Mobile.attribute_at_level(character, &1, level))
    end

    def regenerate_hp_and_mana(%Character{hp: _hp, mana: mana} = character, room) do
      max_hp = max_hp_at_level(character, character.level)
      max_mana = max_mana_at_level(character, character.level)

      base_regen_per_round = attribute_at_level(character, :willpower, character.level) / 5

      hp_regen_percentage_per_round = base_regen_per_round * (1 + ability_value(character, "HPRegen") / 100) / max_hp
      mana_regen_percentage_per_round =
        if max_mana > 0 do
          base_regen_per_round * (1 + ability_value(character, "ManaRegen") / 100) / max_mana
        else
          0
        end

      character
      |> shift_hp(hp_regen_percentage_per_round, room)
      |> Map.put(:mana, min(mana + mana_regen_percentage_per_round, 1.0))
      |> update_prompt()
    end

    def round_length_in_ms(character) do
      agility = attribute_at_level(character, :agility, character.level)

      base =
        if agility > 1000 do
          4000 * :math.pow(0.9997, 1000) * :math.pow(0.999925, agility - 1000)
        else
          4000 * :math.pow(0.9997, agility)
        end

      speed_mods =
        character.effects
        |> Map.values
        |> Enum.filter(&(Map.has_key?(&1, "Speed")))
        |> Enum.map(&(Map.get(&1, "Speed")))

      count = length(speed_mods)

      if count > 0 do
        trunc(base * (Enum.sum(speed_mods) / count / 100))
      else
        base
      end
    end

    def send_scroll(%Character{socket: socket} = character, html) do
      send(socket, {:scroll, html})
      character
    end

    def set_room_id(%Character{socket: socket, monitor_ref: monitor_ref} = character, room_id) do
      Process.demonitor(monitor_ref)

      send(character.socket, {:update_character, %{room_id: room_id, power: Mobile.power_at_level(character, character.level), level: character.level}})

      character
      |> Map.put(:room_id, room_id)
      |> Map.put(:monitor_ref, Process.monitor(socket))
      |> Repo.save!
    end

    def shift_hp(character, percentage, room) do
      hp_description = hp_description(character)
      character = update_in(character.hp, &(min(1.0, &1 + percentage)))
      updated_hp_description = hp_description(character)

      if character.hp > 0 and hp_description != updated_hp_description do
        room.mobiles
        |> Map.values
        |> Enum.reject(& &1.ref == character.ref)
        |> Enum.each(fn
             %Character{} = observer ->
               Mobile.send_scroll(observer, "<p>#{Mobile.colored_name(character, observer)} is #{updated_hp_description}.</p>")
             _ ->
               :noop
           end)
      end

      character
    end

    def silenced(%Character{effects: effects} = character, %Room{} = room) do
      effects
      |> Map.values
      |> Enum.find(fn(effect) ->
           Map.has_key?(effect, "Silence")
         end)
      |> silenced(character, room)
    end
    def silenced(nil, %Character{}, %Room{}), do: false
    def silenced(%{}, %Character{} = character, %Room{}) do
      Mobile.send_scroll(character, "<p><span class='cyan'>You are silenced!</span></p>")
      true
    end

    def spellcasting_at_level(character, level, room) do
      will = attribute_at_level(character, :willpower, level)
      cha = Party.charm_at_level(room, character, level)
      will = will + (cha / 10)
      modifier = ability_value(character, "Spellcasting")
      will * (1 + (modifier / 100))
    end

    def abilities_at_level(%Character{abilities: abilities}, level) do
      abilities
      |> Map.values
      |> Enum.filter(& &1.level <= level)
      |> Enum.sort_by(& &1.level)
    end

    def stealth_at_level(character, level, room) do
      if Mobile.has_ability?(character, "Revealed") do
        0
      else
        agi = attribute_at_level(character, :agility, level)
        agi = agi + (Party.charm_at_level(room, character, level) / 10)
        modifier = ability_value(character, "Stealth")
        agi * (modifier / 100)
      end
    end

    def subtract_mana(character, ability) do
      cost = Ability.mana_cost_at_level(ability, character.level)
      percentage = cost / Mobile.max_mana_at_level(character, character.level)
      update_in(character.mana, &(max(0, &1 - percentage)))
    end

    def target_level(%Character{level: _caster_level}, %Character{level: target_level}), do: target_level
    def target_level(%Character{level: _caster_level}, %Companion{level: target_level}), do: target_level
    def target_level(%Character{level: caster_level}, %Monster{level: target_level}), do: max(caster_level, target_level)

    def tracking_at_level(character, level, room) do
      perception = perception_at_level(character, level, room)
      modifier = ability_value(character, "Tracking")
      perception * (modifier / 100)
    end

    def update_prompt(%Character{socket: socket} = character) do
      send(socket, {:update_prompt, Character.prompt(character)})
      character
    end
  end

end
