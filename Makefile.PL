use ExtUtils::MakeMaker;

my $req =  { 
	'Time::HiRes'  => 0,
	'File::Copy'   => 0,
	'File::Util'   => 0,
	'EV'		   => 0,
	'Guard'		   => 0,
	
	# for tests
	'AnyEvent::HTTP' => 0,
	'HTTP::Request::Common' => 0,
};

$| = 1;

unless (eval { require IO::AIO }){
	print "- Install IO::AIO for asynchronous disk IO? [y] : ";

	$_ = <STDIN>;
	unless( m/n/i ){
		$req->{'IO::AIO'} = 0;
		$req->{'AnyEvent::AIO'} = 0;
	}
}else {
	$req->{'AnyEvent::AIO'} = 0;
}

my %options = (
  'TYPEMAPS' => [],
  'NAME' => 'HTTP::Server::EV',
  'VERSION' => '0.41',
  'OPTIMIZE' => ' -O2',
  'BUILD_REQUIRES' => $req,
  
  'CONFIGURE_REQUIRES' => {
	'EV' => 0
  },

  
  'CONFIGURE' => sub {
	require EV::MakeMaker;
	return {EV::MakeMaker::ev_args(my %tmp)};
  },
  
  
);
WriteMakefile(%options);

# Remove the Makefile dependency. Causes problems on a few systems.
sub MY::makefile { '' }