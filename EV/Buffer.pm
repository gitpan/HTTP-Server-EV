package HTTP::Server::EV::Buffer;
our $VERSION = '0.3';

use strict;
use bytes;
use EV;
use Scalar::Util qw/weaken/;
use Carp;

=head1 NAME

HTTP::Server::EV::Buffer - Non-blocking output buffer.  

=head1 GLOBAL PARAMETERS

$HTTP::Server::EV::Buffer::autoflush = 1024*50; # Default buffered data size in bytes when buffer starts waiting socket to be writable to send data. Setting 0 disables buffering, data will be send as soon as socket becomes writable.

=cut


our $autoflush = 1024*10; 


=head1 METHODS

=head2 new({ fh => $sock_handle , flush => autoflush threshold(optional), onerror => sub { onerror(disconect) optional callback} });

Creates new HTTP::Server::EV::Buffer object. 

=cut

# when buffer is destroed at main program it will be placed here to send all data, close socket and destroy itself completely
our %buffers; 

#$self->{status} = 
# 0 - flush buffer until buffred data greater than autoflush threshold (default)
# 1 - flush entire buffer and set status to 0 (->flush call)
# 2 - flush entire buffer, delete watcher and close socket(on DESTROY)



sub new {
	my ($name, $self) = @_;
	
	$self->{flush} = $autoflush unless exists $self->{flush};
	
	$self->{fd} = fileno $self->{fh};
	
	# break circular because onneror possible contains closure with H:S:E::CGI object that contains ref to buffer
	#weaken $self->{onerror} if $self->{onerror};
	
	weaken $self; # break circular ref. 
	
	$self->{w} = EV::io_ns $self->{fh}, EV::WRITE, sub {
	
		my $bytes = send(
			$self->{fh}, 
			( $self->{flush} ? substr($self->{buffer}, 0, $self->{flush}) : $self->{buffer}),
			0
		);
		
		unless( defined $bytes ){ # socket closed
			delete $self->{buffer};
	#		$self->{onerror}->() if $self->{onerror};
		}
		
		substr($self->{buffer}, 0, $bytes) = ''; # delete sent data
		
		if( length($self->{buffer}) <= $self->{flush} ){
			if($self->{status}){
				if( length $self->{buffer} ){
					return;
				}else{
					if( $self->{status} == 1 ){
						$self->{status} = 0;
					}else{
						delete $buffers{$self->{fd}};
						return; # now it calls DESTROY again and closes the socket
					}
				}
			}
			$_[0]->stop;
		}
		
	};
	
	bless $self, $name;
}


sub TIEHANDLE { # pkgname, buffer obj
	return $_[1];
}

*TIESCALAR=\&TIEHANDLE;


=head2 $buffer->print(@args);

Prints data to buffer.

=cut






sub WRITE {
	$_[0]->{buffer} .=  substr $_[1], 0, $_[2];
	$_[0]->{w}->start if(length($_[0]->{buffer}) > $_[0]->{flush});
}


sub print {
	my $self = shift;
	
	$self->{buffer} .= join( ($, // ''), @_) . ($\ // '');
	
	$self->{w}->start if(length($self->{buffer}) > $self->{flush});
}

*PRINT=\&print;

sub PRINTF {
	my $self = shift;
	
	$self->{buffer} .= sprintf(shift, @_);
	
	$self->{w}->start if(length($self->{buffer}) > $self->{flush});
}



=head2 $buffer->flush( $flush_threshold(optional) );

Sends all buffered data to socket and sets new flush threshold if $flush_threshold defined;

=cut


sub flush {
	$_[0]->{flush} = $_[1] if defined $_[1];
	
	if(length $_[0]->{buffer}){
		$_[0]->{status} = 1;
		$_[0]->{w}->start;
	}
}


=head1 TODO

Implement onerror callback

=cut


sub DESTROY {
	if(length $_[0]->{buffer}){
		$_[0]->{status} = 2;
		$_[0]->{w}->start;
		$buffers{$_[0]->{fd}} = $_[0];
	}else{
		close $_[0]->{fh};
	}
}


# read-only

sub READLINE { croak "HTTP::Server::EV::Buffer doesn't support a READLINE method"; }
sub GETC { croak "HTTP::Server::EV::Buffer doesn't support a GETC method"; }
sub READ { croak "HTTP::Server::EV::Buffer doesn't support a READ method"; }



1;