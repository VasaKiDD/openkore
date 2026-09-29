#########################################################################
#  claudeBridge - local JSON API for AI agents
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#########################################################################
#
# Lets an external program (mcp_server.py, which exposes it to Claude as
# MCP tools) observe and control this bot over HTTP. OpenKore's own AI keeps
# doing the real-time work (walking, fighting, looting); the agent reads the
# state, runs console commands and changes config.
#
# The server is part of the OpenKore main loop and never blocks it.
#
# config.txt:
#   claudeBridge_port 7777          TCP port
#   claudeBridge_bind 127.0.0.1     keep it on loopback: /command can run any console command
#   claudeBridge_token              optional; when set, every request needs ?token=<value>
#   claudeBridge_charName           optional; for headless bots: create this character when
#                                   the account has none, and always log in without the menu
#
# Endpoints (GET, JSON responses):
#   /health                         plugin, connection and event counter
#   /state                          character status, position, AI state
#   /nearby?limit=N&kinds=a,b       monsters, players, npcs, items, portals, nearest first
#   /inventory                      items; "id" is the inventory index used by commands
#   /skills                         learned skills
#   /npc                            current NPC dialog and recent NPC messages
#   /events?since=SEQ&limit=N       game events (hooks and selected console messages)
#   /command?cmd=TEXT               run a console command, returns its console output
#   /config?key=K[&value=V]         read a config.txt key, or set it through 'conf'
package claudeBridge;

use strict;
use Time::HiRes qw(time);
use JSON::PP;
use Scalar::Util qw(blessed);
use Plugins;
use Globals;
use Log qw(message warning error);
use Commands;
use AI;
use Misc;
use Skill;
use Utils;

our $path;
BEGIN {
	$path = $Plugins::current_plugin_folder;
}
use lib $path;
use ClaudeBridgeServer;

use constant {
	VERSION          => '1.0',
	DEFAULT_PORT     => 7777,
	DEFAULT_BIND     => '127.0.0.1',
	MAX_EVENTS       => 500,
	MAX_OUTPUT_LINES => 200,
	DEFAULT_NEARBY   => 20,
};

# Hooks whose arguments are recorded as events. A hook the current server
# type never calls just never fires.
my @EVENT_HOOKS = qw(
	in_game disconnected self_died target_died
	base_level_changed job_level_changed item_gathered
	npc_talk npc_talk_responses npc_talk_done
	packet_pubMsg packet_privMsg packet_partyMsg packet_guildMsg packet_sentPM packet_selfChat
	packet_mapChange
);

# Console message domains recorded as events, in addition to every warning and error.
my %EVENT_LOG_DOMAINS = map { $_ => 1 } qw(
	npc pm pm/sent publicchat partychat guildchat schat selfchat
	connection success teleport
);

my %AI_MODES = (0 => 'off', 1 => 'manual', 2 => 'auto');
my @NEARBY_KINDS = qw(monsters players npcs items portals);

my $json = JSON::PP->new->utf8->canonical->allow_nonref;
my $server;
my @events;
my $eventSeq = 0;
my $capture;    # array ref of console lines while /command runs

Plugins::register('claudeBridge', 'Local JSON API for AI agents (see mcp_server.py)', \&onUnload);
my $hooks = Plugins::addHooks(
	['start3',           \&onStart],
	['mainLoop_post',    \&onMainLoop],
	['charSelectScreen', \&onCharSelect],
	map { [$_, \&onEventHook] } @EVENT_HOOKS
);
my $logHook = Log::addHook(\&onLog);

sub onUnload {
	Plugins::delHooks($hooks);
	Log::delHook($logHook);
	undef $server;
}

sub onStart {
	my $port = $config{claudeBridge_port} || DEFAULT_PORT;
	my $bind = $config{claudeBridge_bind} || DEFAULT_BIND;
	eval {
		$server = new ClaudeBridgeServer($port, $bind, \&handleRequest);
	};
	if ($server) {
		message "[claudeBridge] Listening on http://$bind:$port/\n", 'connection';
	} else {
		error "[claudeBridge] Cannot listen on $bind:$port: $@\n";
	}
}

sub onMainLoop {
	$server->iterate if $server;
}

# The character menu waits for keyboard input, which a headless bot never gets.
# With claudeBridge_charName set, create that character on an empty account and
# log in without the menu (OpenKore shows it again right after a creation).
sub onCharSelect {
	my (undef, $args) = @_;
	my $name = $config{claudeBridge_charName};
	return unless defined $name && $name ne '';
	my $slot = defined $config{char} && $config{char} =~ /^\d+$/ ? $config{char} : 0;

	if ($chars[$slot] && %{$chars[$slot]}) {
		return if $args->{autoLogin};    # OpenKore's own auto-login takes it from here
		$messageSender->sendCharLogin($slot);
		$timeout{charlogin}{time} = time;
		$args->{return} = 1;
		return;
	}

	message "[claudeBridge] No character in slot $slot, creating \"$name\"\n", 'connection';
	configModify('char', $slot, 1) unless defined $config{char} && $config{char} eq $slot;
	$timeout{charlogin}{time} = time;
	$args->{return} = 1 if Misc::createCharacter($slot, $name, 1, 1);
}

##### Events

sub pushEvent {
	my ($type, $data) = @_;
	push @events, {seq => ++$eventSeq, time => int(time * 1000) / 1000, type => $type, data => $data};
	shift @events while @events > MAX_EVENTS;
}

sub onEventHook {
	my ($hookName, $args) = @_;
	pushEvent($hookName, plain($args));
}

sub onLog {
	my ($type, $domain, $level, $verbosity, $msg) = @_;
	return if $type eq 'debug' || !defined $msg;

	if ($capture && $level <= $verbosity && @$capture < MAX_OUTPUT_LINES) {
		push @$capture, grep { $_ ne '' } split /\r?\n/, $msg;
	}
	if ($type eq 'warning' || $type eq 'error' || $EVENT_LOG_DOMAINS{$domain}) {
		my $text = $msg;
		$text =~ s/\s+$//;
		pushEvent("log/$type", {domain => $domain, text => $text}) if $text ne '';
	}
}

##### Request handling

sub handleRequest {
	my ($process) = @_;
	my $args = $process->GET;
	my $token = $config{claudeBridge_token};
	if (defined $token && $token ne '' && (!defined $args->{token} || $args->{token} ne $token)) {
		return respond($process, 403, {error => 'missing or wrong token'});
	}

	my $file = $process->file;
	my $data = eval {
		if ($file eq '/' || $file eq '/health') {
			health();
		} elsif ($file eq '/state') {
			charState();
		} elsif ($file eq '/nearby') {
			my @kinds = $args->{kinds} ? split(/\s*,\s*/, $args->{kinds}) : @NEARBY_KINDS;
			nearby(positiveInt($args->{limit}, DEFAULT_NEARBY), \@kinds);
		} elsif ($file eq '/inventory') {
			inventory();
		} elsif ($file eq '/skills') {
			skills();
		} elsif ($file eq '/npc') {
			npcDialog();
		} elsif ($file eq '/events') {
			eventsSince($args->{since}, positiveInt($args->{limit}, 100));
		} elsif ($file eq '/command') {
			defined $args->{cmd} && $args->{cmd} ne '' ? runCommand($args->{cmd}) : {error => 'cmd is required'};
		} elsif ($file eq '/config') {
			configEntry($args->{key}, $args->{value});
		} else {
			undef;
		}
	};
	if ($@) {
		my $err = "$@";
		$err =~ s/\s+$//;
		return respond($process, 500, {error => $err});
	}
	return respond($process, 404, {error => "unknown endpoint $file"}) unless defined $data;
	return respond($process, $data->{error} ? 400 : 200, $data);
}

sub respond {
	my ($process, $code, $data) = @_;
	my $body = $json->encode($data);
	$process->status($code, $code == 200 ? 'OK' : 'Error');
	$process->header('Content-Type', 'application/json; charset=utf-8');
	$process->header('Cache-Control', 'no-store');
	$process->shortResponse($body);
}

##### Endpoints

sub health {
	return {
		plugin     => 'claudeBridge',
		version    => VERSION,
		connection => num($conState),
		inGame     => bool(inGame()),
		character  => $char ? $char->{name} : undef,
		map        => mapName(),
		latestSeq  => $eventSeq,
	};
}

sub charState {
	return {inGame => JSON::PP::false, connection => num($conState)} unless inGame();
	my $pos = position($char) || {};
	my %statuses = %{$char->{statuses} || {}};
	my $last = $#ai_seq < 4 ? $#ai_seq : 4;
	return {
		inGame         => JSON::PP::true,
		name           => $char->{name},
		job            => jobName($char->{jobID}),
		baseLevel      => num($char->{lv}),
		jobLevel       => num($char->{lv_job}),
		baseExpPercent => percent($char->{exp}, $char->{exp_max}),
		jobExpPercent  => percent($char->{exp_job}, $char->{exp_job_max}),
		hp             => num($char->{hp}),
		hpMax          => num($char->{hp_max}),
		sp             => num($char->{sp}),
		spMax          => num($char->{sp_max}),
		zeny           => num($char->{zeny}),
		weight         => num($char->{weight}),
		weightMax      => num($char->{weight_max}),
		stats          => {map { $_ => num($char->{$_}) } qw(str agi vit int dex luk)},
		statusPoints   => num($char->{points_free}),
		skillPoints    => num($char->{points_skill}),
		map            => mapName(),
		x              => $pos->{x},
		y              => $pos->{y},
		sitting        => bool($char->{sitting}),
		dead           => bool($char->{dead}),
		statuses       => [sort map { $statusName{$_} || $_ } keys %statuses],
		ai             => $AI_MODES{AI::state()} || AI::state(),
		currentAction  => AI::action(),
		actionQueue    => [@ai_seq[0 .. $last]],
		lockMap        => $config{lockMap},
		latestSeq      => $eventSeq,
	};
}

sub nearby {
	my ($limit, $kinds) = @_;
	return {inGame => JSON::PP::false} unless inGame();
	my %lists = (
		monsters => $monstersList,
		players  => $playersList,
		npcs     => $npcsList,
		items    => $itemsList,
		portals  => $portalsList,
	);
	my $me = position($char) || {};
	my %out = (map => mapName(), x => $me->{x}, y => $me->{y});

	foreach my $kind (@$kinds) {
		my $list = $lists{$kind} or next;
		my @entries;
		foreach my $actor (@{$list->getItems()}) {
			next unless $actor;
			my $entry = actorSummary($actor);
			delete $entry->{kind};
			$entry->{dist} = tileDistance($me, $entry);
			addKindFields($kind, $actor, $entry);
			push @entries, $entry;
		}
		@entries = sort { ($a->{dist} // 9999) <=> ($b->{dist} // 9999) } @entries;
		splice(@entries, $limit) if @entries > $limit;
		$out{$kind} = \@entries;
	}
	return \%out;
}

sub addKindFields {
	my ($kind, $actor, $entry) = @_;
	if ($kind eq 'monsters') {
		$entry->{dmgToYou}   = num($actor->{dmgToYou})   if $actor->{dmgToYou};
		$entry->{dmgFromYou} = num($actor->{dmgFromYou}) if $actor->{dmgFromYou};
	} elsif ($kind eq 'players') {
		$entry->{job}   = jobName($actor->{jobID});
		$entry->{level} = num($actor->{lv}) if $actor->{lv};
		$entry->{guild} = $actor->{guild}{name} if ref $actor->{guild} eq 'HASH';
	} elsif ($kind eq 'items') {
		$entry->{amount} = num($actor->{amount});
	}
}

sub inventory {
	return {inGame => JSON::PP::false} unless inGame();
	my @items;
	foreach my $item (@{$char->inventory->getItems()}) {
		next unless $item;
		push @items, {
			id         => num($item->{binID}),
			name       => itemName($item),
			nameID     => num($item->{nameID}),
			amount     => num($item->{amount}),
			type       => $itemTypes_lut{$item->{type}} || num($item->{type}),
			equipped   => bool($item->{equipped}),
			identified => bool($item->{identified}),
		};
	}
	return {
		zeny      => num($char->{zeny}),
		weight    => num($char->{weight}),
		weightMax => num($char->{weight_max}),
		items     => \@items,
	};
}

sub skills {
	return {inGame => JSON::PP::false} unless inGame();
	my @out;
	my $learned = $char->{skills} || {};
	foreach my $handle (sort keys %$learned) {
		my $skill = $learned->{$handle};
		next unless ref $skill eq 'HASH' && $skill->{lv};
		my $name = eval { Skill->new(handle => $handle)->getName() };
		push @out, {
			id         => num($skill->{ID}),
			handle     => $handle,
			name       => $name || $handle,
			level      => num($skill->{lv}),
			sp         => num($skill->{sp}),
			range      => num($skill->{range}),
			upgradable => bool($skill->{up}),
		};
	}
	return {skillPoints => num($char->{points_skill}), skills => \@out};
}

sub npcDialog {
	my @recent = grep {
		$_->{type} =~ /^npc_talk/
		  || ($_->{type} eq 'log/message' && $_->{data}{domain} eq 'npc')
	} @events;
	splice(@recent, 0, @recent - 15) if @recent > 15;
	return {
		active    => bool(%talk && $talk{ID}),
		talk      => plain(\%talk),
		recent    => \@recent,
		latestSeq => $eventSeq,
	};
}

sub eventsSince {
	my ($since, $limit) = @_;
	my @out;
	if (defined $since && $since =~ /^\d+$/) {
		@out = grep { $_->{seq} > $since } @events;
		splice(@out, $limit) if @out > $limit;    # oldest first, page forward with since=<last seq>
	} else {
		@out = @events;
		splice(@out, 0, @out - $limit) if @out > $limit;    # no cursor: the newest events
	}
	return {latestSeq => $eventSeq, events => \@out};
}

sub runCommand {
	my ($cmd) = @_;
	my @lines;
	$capture = \@lines;
	my $ok = eval { Commands::run($cmd); 1 };
	my $err = $@;
	undef $capture;
	my %result = (command => $cmd, output => \@lines, latestSeq => $eventSeq);
	if (!$ok) {
		$err =~ s/\s+$//;
		$result{error} = $err;
	}
	return \%result;
}

sub configEntry {
	my ($key, $value) = @_;
	return {error => 'key is required'} unless defined $key && $key =~ /^[\w.]+$/;
	if (defined $value) {
		my $result = runCommand("conf $key $value");
		$result->{key}   = $key;
		$result->{value} = $config{$key};
		return $result;
	}
	return {key => $key, value => $config{$key}};
}

##### Helpers

sub inGame {
	return defined $conState && $conState == 5 && $char ? 1 : 0;
}

sub mapName {
	return undef unless $field;
	my $name = eval { $field->baseName } || eval { $field->name };
	return $name;
}

sub jobName {
	my ($jobID) = @_;
	return undef unless defined $jobID;
	return $jobs_lut{$jobID} || "job $jobID";
}

sub itemName {
	my ($item) = @_;
	my $name = eval { $item->name };
	return defined $name ? $name : $item->{name};
}

sub position {
	my ($actor) = @_;
	my $pos = eval { calcPosition($actor) };
	$pos = $actor->{pos_to} || $actor->{pos} unless ref $pos eq 'HASH' && defined $pos->{x};
	return undef unless ref $pos eq 'HASH' && defined $pos->{x};
	return {x => $pos->{x} + 0, y => $pos->{y} + 0};
}

# Distance in cells, as RO measures ranges (Chebyshev distance).
sub tileDistance {
	my ($from, $to) = @_;
	return undef unless defined $from->{x} && defined $to->{x};
	my $dx = abs($from->{x} - $to->{x});
	my $dy = abs($from->{y} - $to->{y});
	return $dx > $dy ? $dx : $dy;
}

# Compact description of an actor (monster, player, NPC, item, portal, you).
sub actorSummary {
	my ($actor) = @_;
	my %out;
	(my $kind = ref $actor) =~ s/^Actor:://;
	$out{kind} = $kind;
	$out{id}     = num($actor->{binID})  if defined $actor->{binID};
	$out{nameID} = num($actor->{nameID}) if defined $actor->{nameID};
	my $name = eval { $actor->name };
	$out{name} = defined $name ? $name : $actor->{name};
	my $pos = position($actor);
	@out{qw(x y)} = @{$pos}{qw(x y)} if $pos;
	return \%out;
}

# Turns hook arguments and game state into JSON-safe data: actors become
# summaries, binary IDs become hex, code refs and deep structures are dropped.
sub plain {
	my ($value, $depth) = @_;
	$depth ||= 0;
	return undef unless defined $value;
	if (blessed $value) {
		return $value->isa('Actor') ? actorSummary($value) : undef;
	}
	my $ref = ref $value;
	return scalarValue($value) unless $ref;
	return undef if $depth >= 3;
	if ($ref eq 'ARRAY') {
		my $last = $#$value < 49 ? $#$value : 49;
		return [map { plain($_, $depth + 1) } @{$value}[0 .. $last]];
	}
	if ($ref eq 'HASH') {
		my %out;
		foreach my $key (keys %$value) {
			next if $key eq 'return' || $key =~ /^_/;
			my $converted = plain($value->{$key}, $depth + 1);
			$out{$key} = $converted if defined $converted;
		}
		return \%out;
	}
	return $ref eq 'SCALAR' ? plain($$value, $depth + 1) : undef;
}

sub scalarValue {
	my ($s) = @_;
	return $s + 0 if $s =~ /^-?(?:0|[1-9]\d{0,14})(?:\.\d+)?$/;
	return unpack('H*', $s) if $s =~ /[\x00-\x08\x0B\x0C\x0E-\x1F]/;    # binary ID
	return $s;
}

sub num {
	my ($value) = @_;
	return undef unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
	return $value + 0;
}

sub bool {
	return $_[0] ? JSON::PP::true : JSON::PP::false;
}

sub percent {
	my ($value, $max) = @_;
	return undef unless $max;
	return int(($value || 0) * 1000 / $max) / 10;
}

sub positiveInt {
	my ($value, $default) = @_;
	return defined $value && $value =~ /^\d+$/ && $value > 0 ? $value + 0 : $default;
}

1;
