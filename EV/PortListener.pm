package HTTP::Server::EV::PortListener;
use strict;
our $VERSION = '0.5';

=head1 NAME

HTTP::Server::EV::PortListener - Port listener

=head1 METHODS

=head2 $listener->stop;

Stops listening port. All already running requests will be processed

=head2 $listener->start;

Starts listening port.

=cut


sub new {bless $_[1];}

sub start {
	HTTP::Server::EV::start_listen($_[0]->{ptr});
}


sub stop {
	HTTP::Server::EV::stop_listen($_[0]->{ptr});
}



1;