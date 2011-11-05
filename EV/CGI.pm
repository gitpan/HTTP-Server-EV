package HTTP::Server::EV::CGI;
use strict;
use bytes;
use Encode;
use Time::HiRes qw(gettimeofday tv_interval);
our $VERSION = '0.2';

=head1 NAME

	HTTP::Server::EV::CGI - Contains http request data and some extra functions.  

=head1 GETTING DATA

=over

=item $cgi->{headers}{header_name} = value

To get last parsed from form value use

=item $cgi->{get}{url_filed_name} = url_filed_value

=item $cgi->{cookies}{cookie_name} = cookie_value

=item $cgi->{post}{form_filed_name} = form_filed_value

=item $cgi->{file}{form_file-filed_name} = L<HTTP::Server::EV::MultipartFile> object

=back

To get reference to array of all elements with same name ( selects, checkboxes, ...) use

=over

=item $cgi->get('filed_name')

=item $cgi->post('filed_name')

=item $cgi->file('filed_name')

=item $cgi->param('filed_name');

=back

Returns one or list of elements depending on call context.
Prefers returning GET values if exists
Never returns L<HTTP::Server::EV::MultipartFile> files, use $cgi->{file}{filed_name} or $cgi->file('filed_name')

All values are utf8 encoded

=head1 METHODS

=cut



our $cookies_lifetime = 3600*24*31;

#$cgi->new({ fd => sock fileno , post => {}, get => {} , headers => {} .... });

# new called only by HTTP::Server::EV 
sub new { 
	my($pkg, $self) = @_;
	
	bless $self, $pkg;
	
	$self->start_timer;
	
	
	open $self->{fh}, '>&='.$self->{fd}; 
	binmode $self->{fh};
	
	## Parse headers. CGI compatible
	( $self->{headers}->{SCRIPT_NAME}, $self->{headers}{QUERY_STRING} ) =(split /\?/, $self->{headers}{REQUEST_URI});
	
	$self->{headers}->{DOCUMENT_URI} = $self->{headers}{SCRIPT_NAME};
	
	for(keys %{$self->{headers}}){
		$self->{headers}->{'HTTP_'.uc($_)}=$self->{headers}->{$_};
	}
	
	$self->{headers}{REMOTE_ADDR} = $self->{headers}->{'HTTP_X-REAL-IP'} if($HTTP::Server::EV::backend && $self->{headers}->{'HTTP_X-REAL-IP'});
	$self->{headers}->{CONTENT_TYPE} = $self->{headers}->{'HTTP_CONTENT-TYPE'};
	$self->{headers}->{CONTENT_LENGTH} = $self->{headers}->{'HTTP_CONTENT-LENGTH'};
	
	


	## Reading get vars
	my @pairs = split(/[;&]/,$self->{headers}{QUERY_STRING},1024);
	foreach (@pairs) {
		my ($name, $data) = split /=/;
		$name = $self->urldecode($name);
		$data = $self->urldecode($data);
		
		$self->{get}{$name} = $data;
		
		$self->{get_a}{$name}=[] unless $self->{get_a}{$name};
		push @{$self->{get_a}{$name}},$data;
	}
	
	## Reading cookies
	@pairs = split(/; /,$self->{headers}{HTTP_COOKIE},100);
	foreach (@pairs) {
		my ($name, $data) = split /=/;
		$self->{cookies}{ $self->urldecode($name) } = $self->urldecode($data);
	}
	

	## Parse urlencoded post
	if($self->{REQUEST_BODY}){
		my @pairs = split(/[;&]/,$self->{REQUEST_BODY},1024);
		foreach (@pairs) {
			my ($name, $data) = split /=/;
			$name = $self->urldecode($name);
			$data = $self->urldecode($data);
			
			$self->{post}{$name} = $data;
					
			$self->{post_a}{$name}=[] unless $self->{post_a}{$name};
			push @{$self->{post_a}{$name}},$data;
		}
	}	
	
	return $self;
}

=head2 $cgi->next;

Ends port listener callback processing. Don`t use it somewhere except HTTP::Server::EV port listener callback

=cut

sub next { goto NEXT_REQ ; };

=head2 $cgi->fd;

Returns file descriptor (int)

=cut

sub fd { shift->{fd} }

=head2 $cgi->fh;

Returns perl file handle

=cut

sub fh { shift->{fh} }




=head2 $cgi->attach(*FH);

Attaches client socket to FH.
	$server->listen( 8080 , sub {
		my $cgi = shift;
		
		$cgi->attach(local *STDOUT); # attach STDOUT to socket
		
		$cgi->header; # print http headers
		
		print "Test page"; 
	});

=cut

sub attach {
	open($_[1], '>&', $_[0]->{fd} ) or die 'Can`t attach socket handle';
	binmode $_[1];
}


=head2 $cgi->close;

Close received socket.

=cut

sub close { 
	CORE::close $_[0]->{fh} ;
	#HTTP::Server::EV::close_socket( $_[0]->{fd} );
};


=head2 $cgi->start_timer

Initalize a page generation timer. Called automatically on every request

=head2 $cgi->flush_timer

Returns string like '0.12345' with page generation time	

=cut


### Page generation timer
sub start_timer { shift->{timer}=[gettimeofday] }; # start/reset timer
sub flush_timer { return tv_interval(shift->{timer}) }; # get generation time

### Get params as array refs. Ex: $cgi->post('checkboxes') - ['one','two']
sub get { return $_[0]->{get_a}{$_[1]} ? $_[0]->{get_a}{$_[1]} : [] ;}
sub post { return $_[0]->{post_a}{$_[1]} ? $_[0]->{post_a}{$_[1]} : [] ;}
sub file { return $_[0]->{file_a}{$_[1]} ? $_[0]->{file_a}{$_[1]} : [] ;}
sub param {
	if(wantarray){
		return @{$_[0]->{get_a}{$_[1]}} || @{$_[0]->{post_a}{$_[1]}};
	}else{
		return $_[0]->{get}{$_[1]} || $_[0]->{post}{$_[1]};
	}
}


=head2 $cgi->set_cookies({ name=> 'value', name2=> 'value2' }, $sec_lifetime );

Takes hashref with cookies as first argumet. Second(optional) argument is cookies lifetime in seconds(1 month by default)

=cut



sub set_cookies {
	my ($self,$cookies, $lifetime)=@_;
	my ($name,$value);
	my @days=qw(Sun Mon Tue Wed Thu Fri Sat);
	my @months=qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my ($sec,$min,$hour,$mday,$mon,$year,$wday)=gmtime( time + ( defined($lifetime) ? $lifetime :  $HTTP::Server::EV::CGI::cookies_lifetime ) );
	my $date = sprintf("%s, %02d-%s-%04d %02d:%02d:%02d GMT",$days[$wday],$mday,$months[$mon],$year+1900,$hour,$min,$sec);
	$self->{cookiesbuffer}.="Set-Cookie: $name=$value; path=/; expires=$date;\r\n" while(($name,$value)=each %{$cookies});
};

# generate headers

=head2 $cgi->header( \%args );

Prints http headers and cookies buffer to socket

Args:

=over

=item STATUS 

HTTP status string. '200 OK' by default

=item Server 

Server header. 'Perl HTTP::Server::EV' by default

=item Content-Type

	Content-Type header. 'text/html' by default

=back

All other args will be converted to headers.

=cut


sub header {
	my ($self,$params)=@_;
	
	my $headers = 'HTTP/1.1 '.($params->{'STATUS'} ? delete($params->{'STATUS'}) : '200 OK')."\r\n";
	$headers .= 'Server: '.($params->{'Server'} ? delete($params->{'Server'}) : 'Perl HTTP::Server::EV')."\r\n";
	$headers .= $self->{cookiesbuffer};
	$headers .= 'Content-Type: '.($params->{'Content-Type'} ? delete($params->{'Content-Type'}) : 'text/html')."\r\n";
	
	$headers .= $_.': '.$params->{$_}."\r\n" for(keys %{$params});
	
	syswrite($self->{fh}, $headers."\r\n");
}


=head2 $cgi->urldecode( $str );

Returns urlecoded utf8 string

=cut

sub urldecode {
	local $_ = $_[1];
	s/\+/ /gs;
	s/%(?:([Dd][0-9a-fA-F])%([0-9a-fA-F]{2})|([0-9a-fA-F]{2}))/
		$1 ? chr(hex $1).chr(hex $2) : decode("cp1251",chr(hex $3))
	/eg;
	Encode::_utf8_on($_);
	return $_;
};
					
sub DESTROY  {
	$_[0]->close;
	for my $arr_ref (values %{$_[0]->{file_a}}){
		$_->del for(@{$arr_ref});
	}
};

1;