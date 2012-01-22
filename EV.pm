package HTTP::Server::EV;

=head1 NAME

HTTP::Server::EV - Asynchronous HTTP server written in C with request parser. 

=head1 DESCRIPTION

HTTP::Server::EV - Asynchronous HTTP server using EV event loop. 
It doesn`t load files received in the POST request in memory as moust of CGI modules does, but stores them directly to tmp files, so it`s useful for handling large files without using a lot of memory. 

=head1 INCLUDED MODULES

L<HTTP::Server::EV::CGI> - received http request object
L<HTTP::Server::EV::MultipartFile> - received file object
L<HTTP::Server::EV::Buffer> - non blocking output
L<HTTP::Server::EV::BufTie> - workaround for correct handling requests in L<Coro> threads

=head1 SYNOPSIS

	my $server = HTTP::Server::EV::CGI->new;
	
	$server->listen(90, sub {
		my $cgi = shift;
		
		$cgi->attach(*STDOUT);
		$cgi->header;

		print "Just another Perl server\n";
	});


=cut


use EV;
use strict;
use Encode;
use Socket;
use utf8;


require Exporter;
*import = \&Exporter::import;
require DynaLoader;

$HTTP::Server::EV::VERSION = '0.3';
DynaLoader::bootstrap HTTP::Server::EV $HTTP::Server::EV::VERSION;

@HTTP::Server::EV::EXPORT = ();
@HTTP::Server::EV::EXPORT_OK = ();

our @sockets;
our $backend;


###################################
use HTTP::Server::EV::CGI;
use HTTP::Server::EV::MultipartFile;


=head1 METHODS


=head2 new( { options } )
	
Options:

=over

=item tmp_path

Directory for saving received files. Tries to create if not found, dies on fail. 
Default: ./upload_tmpfiles/


=item cleanup_on_destroy

Usually HTTP::Server::EV::CGI deletes tmp files on DESTROY, but it might by bug if you delete HTTP::Server::EV::CGI object when its files are still opened. Setting on this flag causes HTTP::Server::EV delete all files in tmp_path on program close, but don`t use it if jou have several process working with same tmp dir.
Default: 0

=item backend

Seting on cause HTTP::Server::EV::CGI parse ip from X-Real-IP http header
Default: 0


=back

=cut

sub new {
	my ($self, $params) = @_;
	
	$params->{tmp_path} = './upload_tmpfiles/' unless($params->{tmp_path});
	unless(-d($params->{tmp_path})){
		mkdir($params->{tmp_path}) or die 'Can`t create path for tmp files!';
	}
	$params->{tmp_path} =~ s|([^/])^|$1/|;
	
	$backend = $params->{backend};
	
	set_tmpdir($params->{tmp_path}); # internal XS method, don`t call it from your program
	
	
	bless $params, $self;
}


=head2 listen( port , sub {callback} )


Binds callback to port. Calls callback and passes HTTP::Server::EV::CGI object in it;
	
	$server->listen( 8080 , sub {
		my $cgi = shift;
		
		$cgi->attach(local *STDOUT); # attach STDOUT to socket
		
		$cgi->header; # print http headers to stdout
		
		print "Test page";
	});

=cut


sub listen{
	my ($self, $port, $cb) = @_;
	
	my $socket;
	socket($socket, AF_INET, SOCK_STREAM, getprotobyname('tcp')) || die "socket: $!";
	setsockopt( $socket, SOL_SOCKET, SO_REUSEADDR, pack('l', 1)) || die "setsockopt: $!";
	bind( $socket, sockaddr_in($port, INADDR_ANY )) || die "bind: $!";
	listen( $socket, SOMAXCONN) || die "listen: $!";
	binmode $socket;
	
	listen_socket($socket, sub { 
		my $stack_pos = shift; # unused
		my $cgi = HTTP::Server::EV::CGI->new(shift);
		
		eval { $cb->($cgi); };
		if($@){ warn "ERROR IN CALLBACK: $@"; }
		
		return;
		
		NEXT_REQ:
		$cgi->close;
	});
	
	push @sockets, $socket;
}


=head2 cleanup

Delete all files in tmp_path. Automatically called on DESTROY if cleanup_on_destroy set

=cut


sub cleanup {
	my @files = glob (shift->{tmp_path}.'*');
	unlink $_ for (@files);
}

sub DESTROY {
	my $self = shift;
	$self->cleanup if($self->{cleanup_on_destroy});
}

sub dl_load_flags {0}; # Prevent DynaLoader from complaining and croaking
1;

=head1 TODO

Write tests

Write request parser error handling - Server drops connection on error(Malformed or too large request), but there is no way to know what error happened.

unbind function

=head1 BUGS/WARNINGS

You can`t create two HTTP::Server::EV objects at same process.

Static allocated buffers:

- Can`t listen more than 20 ports at same time

- 4kb for GET/POST form field names

- 4kb for GET values

- 50kb for POST form field values ( not for files. Files are stored into tmp directly from socket stream, so filesize not limited by HTTP::Server::EV)

HTTP::Server::EV drops connection if some buffer overflows. You can change these values in EV.xs and recompile module.


=head1 COPYRIGHT AND LICENSE

This module is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.
