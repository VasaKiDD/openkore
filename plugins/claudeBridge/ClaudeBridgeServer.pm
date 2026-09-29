#########################################################################
#  OpenKore - claudeBridge web server
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#########################################################################
##
# MODULE DESCRIPTION: HTTP server of the claudeBridge plugin
#
# A thin Base::WebServer subclass. Requests are passed to the handler given
# to new(), which lives in claudeBridge.pl. The server is non-blocking and is
# driven from OpenKore's main loop (see claudeBridge.pl).
package ClaudeBridgeServer;

use strict;
use Base::WebServer;
use base qw(Base::WebServer);

##
# ClaudeBridgeServer ClaudeBridgeServer->new(int port, String bind, CODE handler)
#
# handler is called as handler(Base::WebServer::Process) for every request.
sub new {
	my ($class, $port, $bind, $handler) = @_;
	my $self = $class->SUPER::new($port, $bind);
	$self->{cb_handler} = $handler;
	return $self;
}

sub request {
	my ($self, $process) = @_;
	$self->{cb_handler}->($process);
}

1;
