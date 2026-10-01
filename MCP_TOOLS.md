# openkore MCP server: tool reference

Every action you can ask of the `openkore` MCP server, what it does and what it returns. The server lets
Claude play one Ragnarok Online character (ClaudeBot) through OpenKore. In Claude Code the tools appear as
`mcp__openkore__<name>`.

## How a call travels

```
Claude → MCP tool (plugins/claudeBridge/mcp_server.py, stdio, registered in TronProject/.mcp.json)
       → HTTP GET on 127.0.0.1:7777 (plugins/claudeBridge/claudeBridge.pl, a plugin inside OpenKore)
       → OpenKore (console commands, config, AI) → rAthena server
```

- **The bot must be running** with the plugin loaded: `bot/bot.command start`. Otherwise every tool
  answers `OpenKore bridge not reachable at http://127.0.0.1:7777 ... Is the bot running?`.
- **OpenKore's AI does the real-time work** (walking, auto-attacking, looting, sitting). Most action tools
  start something and return at once; follow the result with `wait_for` or `get_status`.
- **Responses** are compact JSON. A failure comes back as `{"error": "..."}`. Out of the game, the
  observation tools return `{"inGame": false}`.
- **Ids.** The `id` of a monster, player, NPC, item, portal or inventory item is an OpenKore list index
  that can change when the list changes, so look again before reusing an old one. `oid` (hex actor id,
  in `look_around`) stays the same while the actor is around. `nameID` is the item or monster type.
- **Environment:** `OPENKORE_BRIDGE_URL` (default `http://127.0.0.1:7777`), `OPENKORE_BRIDGE_TOKEN` (the
  plugin's `claudeBridge_token`, if set).

## All tools at a glance

| Tool | Kind | What it does |
| --- | --- | --- |
| `get_status` | read | Full character status: level, exp, HP/SP, stats, equipment, party, quests, map, position, AI state |
| `look_around` | read | Nearby monsters, players, NPCs, ground items, portals and ground effects, nearest first |
| `get_inventory` | read | Inventory items with their inventory ids, zeny and weight |
| `get_skills` | read | Learned skills (optionally learnable level-0 ones) and unspent skill points |
| `describe_skill` | read | In-game description of a skill |
| `describe_item` | read | In-game description of an item type |
| `get_map_overview` | read | Coarse text minimap of the whole current map |
| `get_npc_dialog` | read | The open NPC conversation, its choices, and the shop list if a shop is open |
| `get_config` | read | One OpenKore behaviour setting |
| `get_configs` | read | Several behaviour settings in one call |
| `get_storage` | read | Kafra storage contents while it is open |
| `recent_events` | read | The game event log (chat, kills, exp, loot, deaths, NPC text, map changes...) |
| `wait_for` | read | Block until a given kind of event happens (up to 120 s) |
| `move_to` | action | Walk to coordinates, to another map, or into a nearby portal |
| `stop_moving` | action | Stop walking |
| `attack` | action | Attack a monster |
| `pick_up` | action | Pick up an item from the ground |
| `talk_to_npc` | action | Start an NPC conversation and return its first answer |
| `npc_reply` | action | Answer the open NPC dialog: next, choose, number, text, close |
| `use_item` | action | Use an inventory item on yourself |
| `equip` | action | Equip an inventory item |
| `unequip` | action | Take off an equipped item |
| `sit` | action | Sit down |
| `stand` | action | Stand up |
| `emote` | action | Show an emotion bubble |
| `use_skill` | action | Use a skill on yourself, a monster, a player or the ground |
| `raise_stat` | action | Spend status points on STR, AGI, VIT, INT, DEX or LUK |
| `raise_skill` | action | Spend one skill point on a skill |
| `set_ai` | action | Switch OpenKore's AI to auto, manual or off |
| `configure` | action | Change an allowed OpenKore behaviour setting (saved to config.txt) |
| `say` | action | Speak in public, party or guild chat, or whisper a player |
| `run_command` | action | Run any other OpenKore console command, except the blocked ones |
| `drop_item` | destructive | Drop an inventory item on the ground |
| `sell_items` | destructive | Sell inventory items to the open NPC shop |
| `storage_move` | destructive | Move items between inventory and Kafra storage |

---

## Observation tools (read-only)

### `get_status()`

The character's whole state in one call.

Returns: `name`, `job`, `baseLevel`, `jobLevel`, `baseExpPercent`, `jobExpPercent`, `exp`/`expMax`,
`expJob`/`expJobMax`, `hp`/`hpMax`, `sp`/`spMax`, `zeny`, `weight`/`weightMax`; `stats`, `statsBonus` and
`statRaiseCost` (per STR/AGI/VIT/INT/DEX/LUK), `statusPoints`, `skillPoints`; derived stats (`attack`,
`attackBonus`, `matkMin`/`matkMax`, `def`, `defBonus`, `mdef`, `mdefBonus`, `hit`, `flee`, `fleeBonus`,
`critical`, `attackSpeed`, `attackRange`, `walkSpeed`); `equipment` (item name per slot), `party` (name
and members with map, HP, level, job, online), `guild`, `quests` (title, active, missions with
count/goal); `map`, `mapDisplayName`, `isTown`, `mapWidth`/`mapHeight`, `pvp`, `saveMap`, `x`, `y`;
`sitting`, `dead`, `casting`, `muted`, `spirits`, `statuses` and `statusDetails` (with seconds left);
`ai` (auto/manual/off), `currentAction`, `actionQueue`, `lockMap`; `counters` since the bot started
(kills, deaths, baseExp, jobExp, zenyGained, zenySpent, itemsGathered); `latestSeq` (the event counter,
usable as `since_seq` for `wait_for`) and `bootId`.

### `look_around(kinds?, limit=15)`

What is near the character, nearest first, distances in cells.

- `kinds`: any of `monsters`, `players`, `npcs`, `items`, `portals`, `spells` (default: all six).
- `limit`: entries per kind, 1 to 50.

Returns your `map`, `x`, `y`, and one list per kind. Every entry has `id`, `oid`, `name`, `x`, `y`,
`dist` (and `nameID` when it has one). Extra fields:

| Kind | Extra fields |
| --- | --- |
| monsters | `attackingMe`, `hpPercent`, `dmgToYou`, `dmgFromYou`, `missedYou`, `casting`, `ignored` |
| players | `job`, `level`, `guild`, `party`, `sitting`, `dead` |
| items (on the ground) | `amount` |
| portals | `destKnown` (true when OpenKore's portal table knows the destination; the name then reads `map -> destination`) |
| spells (ground effects: warp portals, traps, fire walls...) | `source` (oid of the caster) |

Use the ids with `attack`, `pick_up`, `talk_to_npc`, `move_to(portal_id=...)` and `use_skill`.

### `get_inventory()`

Returns `zeny`, `weight`, `weightMax` and `items`: `id` (inventory id, used by `use_item`, `equip`,
`unequip`, `drop_item`, `sell_items`, `storage_move put`), `name`, `nameID`, `amount`, `type`, `equipped`,
`identified`.

### `get_skills(include_unlearned=false)`

Returns `skillPoints` and `skills`: `id` (used by `use_skill` and `raise_skill`), `handle` (e.g.
`NV_BASIC`), `name`, `level`, `sp` cost, `range`, `targetType`, `upgradable`. With
`include_unlearned=true`, level-0 skills the character could learn are listed too.

### `describe_skill(skill)`

The description a player reads in the skill window. `skill` is an id, a handle (`NV_BASIC`) or a name.
Returns `id`, `handle`, `name`, `description` (up to 1500 characters), `targetType`, and `level`/`sp`
when the character knows the skill.

### `describe_item(name_id)`

The description a player reads in the item window. `name_id` is the item type (`nameID` from
`get_inventory` or `look_around`, not the inventory id). Returns `nameID`, `name`, `description`.

### `get_map_overview(cols=40, rows=20)`

A coarse picture of the whole current map, like the minimap. `cols` 10 to 120, `rows` 5 to 60.

Returns `map`, `displayName`, `isTown`, `width`, `height`, `scale` (cells per character), your `x`, `y`,
a `legend`, and `rows` (top row = north edge, first column = x 0):

```
.  walkable    #  blocked    @  you    P  portal    N  NPC    M  monster    p  player
```

### `get_npc_dialog()`

The conversation as it stands now, without acting. Returns `active` (a dialog is open), `npc` (name),
`text` (the accumulated dialog text), `choices` (`[{index, text}]`), `store` (`[{id, nameID, name,
price}]` when a shop's buy list is open) and `store_npc`.

### `get_config(key)`

One OpenKore `config.txt` behaviour setting, e.g. `lockMap`, `attackAuto`. Returns `{key, value}`.
Account, login, connection and bridge settings (anything with pass, pin, token, secret, username,
master, server, char, email, `alias_`, `claudeBridge_`) are refused.

### `get_configs(keys)`

Several settings at once. Returns `{"values": {key: value or null}}`, plus `refused` listing the keys
that are not readable.

### `get_storage()`

The Kafra storage while it is open (talk to a Kafra employee and choose Storage first). Returns `open`,
`title`, and `items`: `id` (the storage id that `storage_move take` uses), `name`, `nameID`, `amount`,
`type`, `identified`.

### `recent_events(since_seq?, limit=100)`

The event log the plugin keeps (a ring of the last 2000 events). With `since_seq`, the events after it,
oldest first; without it, the newest ones. `limit` 1 to 200.

Returns `latest_seq`, `oldest_seq` (oldest still kept), `boot_id` (changes when the bot restarts, and
sequence numbers start again from 0) and `events`: `seq`, `type`, `time` (epoch seconds) and either
`data` (always a dict) or, for console messages, `domain` and `text`. The event types are listed under
"Events" below.

### `wait_for(event_types?, timeout_seconds=30, since_seq?)`

Waits until a matching event happens, instead of polling `get_status`.

- `event_types`: prefixes of event types, e.g. `["target_died"]`, `["self_died", "base_level_changed"]`,
  `["npc_talk"]` (matches all three NPC events), `["log/pm"]`. Console messages match both their type
  (`log/message`, `log/warning`, `log/error`) and `log/<domain>`. Omit it to return on any event.
- `timeout_seconds`: 1 to 120.
- `since_seq`: count events after this number (for example `latestSeq` from `get_status`, so nothing
  that happened in between is missed). Without it, only events after the call count.

Returns `timed_out`, `matched` (up to 20), `other_events` (up to 15), `latest_seq`, and a short `status`
(name, levels, HP/SP, map, position, dead, sitting, current action, weight).

---

## Action tools

Unless stated otherwise, an action tool sends one OpenKore console command and returns
`{"command": "...", "output": [console lines]}`. The output says whether OpenKore accepted the command,
not whether the game action succeeded; check with `wait_for` or the next observation.

### `move_to(x?, y?, map?, portal_id?)`

Walks somewhere, in the background. Four forms:

| Arguments | Effect | Console |
| --- | --- | --- |
| `x`, `y` | a cell on the current map | `move x y` |
| `x`, `y`, `map` | a cell on another map (OpenKore routes through portals) | `move x y map` |
| `map` | anywhere on that map | `move map` |
| `portal_id` | into a nearby portal (id from `look_around`) | `move id` |

Follow the walk with `wait_for(["packet_mapChange", "route"])` or `get_status`.

### `stop_moving()`

Clears the current route (`move stop`).

### `attack(monster_id)`

Attacks a monster by its `look_around` id (`a id`). The AI keeps attacking until the target dies or is
lost; `wait_for(["target_died"])` to know when it ends.

### `pick_up(item_id)`

Picks up a ground item by its `look_around` id (`take id`).

### `talk_to_npc(npc_id)`

Starts a conversation (`talk id`) and waits up to 10 s for the NPC to answer. OpenKore does not walk to
the NPC: be within about 12 cells first. Returns the dialog (`active`, `npc`, `text`, `choices`,
`closed`, a `hint` on how to answer) plus the console `output`.

### `npc_reply(action, value?)`

Answers the open dialog and returns the updated dialog (waits up to 6 s for the server).

| `action` | `value` | Effect |
| --- | --- | --- |
| `continue` | none | presses Next (`talk cont`) |
| `choose` | choice index from the dialog | picks a menu entry (`talk resp N`) |
| `number` | a number | answers a number prompt (`talk num N`) |
| `text` | a text | answers a text prompt (`talk text ...`) |
| `close` | none | ends the conversation; when a menu is shown it picks the menu's "Cancel Chat" entry, which is the only cancel that does not leave the AI stuck |

### `use_item(item_id)`

Uses an inventory item on yourself (potion, food, Fly Wing...): `is id`.

### `equip(item_id)` / `unequip(item_id)`

Equips (`eq id`) or takes off (`uneq id`) an item, by inventory id.

### `sit()` / `stand()`

Sits down (faster HP and SP regeneration; needs Basic Skill level 3) or stands up.

### `emote(emotion)`

Shows an emotion above the character (`e ...`): a name or number from OpenKore's emotion table, e.g.
`heh`, `ok`, `hmm`, `!`, `?`.

### `use_skill(skill_id, target="self", target_id?, x?, y?, level?)`

Uses a skill (`skill_id` from `get_skills`), at `level` or the highest learned level.

| `target` | Needs | Console |
| --- | --- | --- |
| `self` | nothing | `ss skill [level]` |
| `monster` | `target_id` from `look_around` | `sm skill id [level]` |
| `player` | `target_id` from `look_around` | `sp skill id [level]` |
| `ground` | `x`, `y` | `sl skill x y [level]` |

### `raise_stat(stat, points=1)`

Spends status points on `str`, `agi`, `vit`, `int`, `dex` or `luk`, 1 to 20 points per call (one
`stat_add` per point). Each point costs more as the stat grows; `statRaiseCost` in `get_status` shows the
price. Returns the last console lines, the new `stats` and the `statusPoints` left.

### `raise_skill(skill_id)`

Spends one skill point on a skill (`skills add id`).

### `set_ai(mode)`

OpenKore's AI mode: `auto` fights, loots, walks and follows its config on its own (`ai on`); `manual`
only does what it is told (`ai manual`); `off` does nothing (`ai off`).

### `configure(key, value)`

Changes an OpenKore behaviour setting, saved to `config.txt` (`conf key value`; the value `none` clears
it). The value must be one line. Only these keys are accepted (the error lists them when you try another):

- **Fighting:** `attackAuto` (0 never, 1 only when attacked, 2 attack monsters around), `attackAuto_party`,
  `attackAuto_onlyWhenSafe`, `attackDistance`, `attackMaxDistance`, `attackUseWeapon`, `attackCanSnipe`,
  `attackCheckLOS`, `runFromTarget`, `runFromTarget_dist`.
- **Looting:** `itemsTakeAuto` (0 none, 1 after the fight, 2 during it), `itemsGatherAuto`,
  `itemsMaxWeight`, `itemsMaxWeight_sellOrStore`.
- **Where to be:** `lockMap` (the map to stay on and farm), `lockMap_x`, `lockMap_y`, `lockMap_randX`,
  `lockMap_randY`, `route_randomWalk` (1 = wander looking for monsters), `route_randomWalk_inTown`,
  `route_randomWalk_maxRouteTime`, `route_step`, `saveMap`, `saveMap_warpToBuyOrSell`.
- **Resting:** `sitAuto_hp_lower` / `sitAuto_hp_upper` (sit below, stand above this HP %),
  `sitAuto_sp_lower`, `sitAuto_sp_upper`, `sitAuto_idle`, `sitAuto_look`.
- **Escaping:** `teleportAuto_hp`, `teleportAuto_idle`, `teleportAuto_search`,
  `teleportAuto_minAggressives`, `teleportAuto_deadly`, `teleportAuto_maxDmg` (all need a Teleport skill
  or Fly Wings).
- **Other:** `dcOnDeath`, `autoTalkCont`, `partyAuto`, `sellAuto`, `storageAuto`, `buyAuto`.
- **Key families** (any key starting with): `useSelf_item_` (e.g. `useSelf_item_0 Red Potion` with
  `useSelf_item_0_hp < 50%`), `useSelf_skill_`, `attackSkillSlot_`, `attackComboSlot_`, `buyAuto_`,
  `sellAuto_`, `storageAuto_`, `getAuto_`.

Returns the console output, the `key` and its new `value`.

### `say(message, to?, channel="public")`

Speaks in `public` chat (everyone nearby reads it, `c`), `party` (`p`) or `guild` (`g`), or whispers a
player when `to` is given (`pm "name" message`; the channel is then ignored).

### `run_command(command_line)`

Runs any other OpenKore console command and returns its output. One command per call (`;;` is refused)
and config aliases are refused. These verbs are blocked, because they move items irreversibly, run
code, send raw packets, or stop, reconnect or reconfigure the bot:

```
eval send sendraw drop sell storage cart deal vender openshop closeshop quit relog charselect
reload plugin conf dump rc rc2 switchconf timeout misc_conf connect create   and every gm* command
```

Use `drop_item`, `sell_items`, `storage_move` and `configure` instead of the blocked item and config
verbs. See "Useful console commands" below for what is left.

---

## Irreversible item tools (destructive)

These check the inventory first and refuse equipped items (`unequip` first).

### `drop_item(item_id, amount?)`

Drops an inventory item on the ground, where other players can take it (`drop id [amount]`). Returns the
console output and the item's name.

### `sell_items(items)`

Sells to the NPC shop that is open in Sell mode (talk to a merchant and choose Sell first). `items` is a
list like `[{"item_id": 3, "amount": 5}, {"item_id": 7}]` (no amount = the whole stack). Everything is sold
in one transaction (`sell id amount` per item, then `sell done`); on any error the sale is cancelled
(`sell cancel`). Returns `sold` (the names) and the console output.

### `storage_move(direction, item_id, amount?)`

Moves items between inventory and Kafra storage (open it with a Kafra NPC first). `put`: `item_id` is an
inventory id (`storage add`). `take`: `item_id` is a storage id from `get_storage` (`storage get`).

---

## Events

What `wait_for` and `recent_events` can see. Match them by type prefix.

| Topic | Event types |
| --- | --- |
| Life and death | `self_died`, `self_resurrected`, `in_game`, `disconnected` |
| Fighting | `target_died`, `monster_disappeared` (only when the monster died), `exp_gained` (`base`, `job`) |
| Progress | `base_level_changed`, `job_level_changed`, `job_changed` (with job names), `quest_added`, `quest_mission_updated` (with `title`, `target`) |
| Items and zeny | `item_gathered`, `item_appeared`, `inventory_item_removed`, `packet_useitem` (`isSelf`, `item`), `equipped_item`, `unequipped_item`, `zeny_change` |
| NPCs | `npc_talk` (`name`, `msg`), `npc_talk_responses` (`name`, `responses`), `npc_talk_done` |
| Chat | `packet_pubMsg`, `packet_privMsg`, `packet_partyMsg`, `packet_guildMsg`, `packet_sentPM`, `packet_selfChat`, `packet_sysMsg`, `packet_localBroadcast` (author and text) |
| Other players | `player_spawned`, `player_disappeared`, `packet_emotion` (`emotionName`, `actorName`), `party_invite`, `guild_invite` (`guildName`), `incoming_deal` |
| Movement | `packet_mapChange`, `Network::Receive::map_changed`, `route`, `fail_calc_map_route` |
| Body and AI | `changed_status` (`actorName`, `status`), `AI_state_change` |
| Console messages | `log/message`, `log/warning`, `log/error`, also matched as `log/<domain>`: `log/pm`, `log/pm/sent`, `log/publicchat`, `log/partychat`, `log/guildchat`, `log/schat`, `log/selfchat`, `log/npc`, `log/success`, `log/teleport`, `log/attacked`, `log/attackMon`, `log/attackedMiss`, `log/attackMonMiss`, `log/exp`, `log/drop`, `log/skill`, `log/useItem`, `log/emotion` (every warning and error is recorded, whatever its domain) |

Typical waits:

```
["self_died", "base_level_changed", "log/pm"]      while farming (60 to 120 s)
["target_died"]                                     after attack
["packet_mapChange"]                                after move_to another map or a portal
["npc_talk"]                                        while a dialog is running
```

---

## Useful console commands (through `run_command`)

`help <command>` prints the syntax of any of them.

| Purpose | Commands |
| --- | --- |
| Look at yourself | `s` (status), `st` (stats), `i` (inventory), `exp` (experience report), `weight`, `where`, `skills`, `damage` (damage taken report), `showeq` |
| Look around | `ml` (monsters), `pl` (players), `nl` (NPCs), `il` (ground items), `portals`, `spells`, `vl` (vending shops), `petl` |
| Shops | `store` (the open shop list), `buy <shop item #> [amount]` (after choosing Buy at a merchant), `searchshop <item>` (closest known NPC shop) |
| After death and travel | `respawn` (back to the save point), `tele` (random teleport; needs the skill or a Fly Wing), `memo`, `warp` |
| Moving | `north`, `south`, `east`, `west`, `northeast`, `northwest`, `southeast`, `southwest` (5 steps), `follow <player>`, `look <direction>`, `lookp <player>` |
| Fighting | `as` (stop attacking), `kill <player>` (PvP and GvG maps only) |
| NPCs | `talknpc <x> <y> <sequence>` (a whole scripted dialog in one go) |
| Automation | `autosell`, `autobuy`, `autostorage` (start the AI sequences configured by `sellAuto`, `buyAuto`, `storageAuto`) |
| Items | `identify`, `card`, `repair`, `arrowcraft`, `refine`, `cook` |
| Social | `party ...`, `guild ...`, `friend ...`, `ignore ...`, `pml` (quick PM list), `chist` (chat log), `chat ...` (chat rooms) |
| Companions | `pet ...`, `homun ...`, `merc ...`, `falcon`, `pecopeco` |
| Quests and misc | `quest ...`, `achieve ...`, `attendance ...`, `top10`, `who`, `whoami`, `version`, `pause <seconds>` |
| AI internals | `aiv` (current AI sequence), `ai print`, `ai clear` |

---

## Common sequences

- **First look:** `get_status`, then `look_around`.
- **Spend points:** `raise_stat("str", 10)` and so on until `statusPoints` is 0; `get_skills` then
  `raise_skill`.
- **Farm a map:** `configure lockMap <map>`, `configure attackAuto 2`, `configure route_randomWalk 1`,
  `configure useSelf_item_0 Red Potion` and `useSelf_item_0_hp < 50%`, `set_ai auto`, then
  `wait_for(["self_died", "base_level_changed"], 120)` in a loop.
- **Talk to an NPC:** `look_around(["npcs"])`, `move_to` next to it, `wait_for(["route"])` or check the
  position, `talk_to_npc(id)`, then `npc_reply` until `closed` is true.
- **Buy:** `talk_to_npc` the merchant, `npc_reply choose` Buy, `get_npc_dialog` for the `store` list, then
  `run_command("buy <id> <amount>")`.
- **Sell:** `talk_to_npc` the merchant, `npc_reply choose` Sell, then `sell_items([...])`.
- **Store:** `talk_to_npc` a Kafra employee, choose Storage, `get_storage`, then `storage_move`.
- **After a death:** `run_command("respawn")`, then fix what killed you before going back.
