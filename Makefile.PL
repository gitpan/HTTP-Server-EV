use 5.008; #Unicode
use ExtUtils::MakeMaker;
require EV::MakeMaker; #fail earlier in case it's not present

my $req =  { 
	'Time::HiRes'  => 0,
	'File::Copy'   => 0,
	'File::Util'   => 0,
	'EV'		   => 0,
	'Guard'		   => 0,
	'Scalar::Util' => 0,
	'List::Util::XS' => 0, #ensures 'weaken'
};

$| = 1;

unless (eval { require IO::AIO }){
	my $answ = prompt("- Install IO::AIO for asynchronous disk IO?",'y');

	unless( $answ =~ m/n/i ){
		$req->{'IO::AIO'} = 0;
		$req->{'AnyEvent::AIO'} = 0;
	}
}else {
	$req->{'AnyEvent::AIO'} = 0;
}

my %options = (
  'TYPEMAPS' => [],
  'NAME' => 'HTTP::Server::EV',
  'VERSION' => '0.66',
  'OPTIMIZE' => ' -O2',
  'PREREQ_PM' => $req,
  'BUILD_REQUIRES' => { # for tests
    'AnyEvent::HTTP' => 0,
    'HTTP::Request::Common' => 0,
  },
  
  'CONFIGURE_REQUIRES' => {
	'EV' => 0
  },

  
  'CONFIGURE' => sub {
	return {EV::MakeMaker::ev_args(my %tmp)};
  },
  
	MIN_PERL_VERSION => '5.008',
	LICENSE => 'perl',
);
WriteMakefile1(%options);

sub WriteMakefile1 {  #Compatibility code for old versions of EU::MM. Written by Alexandr Ciornii, version 0.23. Added by eumm-upgrade.
	my %params=@_;
	my $eumm_version=$ExtUtils::MakeMaker::VERSION;
	$eumm_version=eval $eumm_version;
	die "EXTRA_META is deprecated" if exists $params{EXTRA_META};
	die "License not specified" if not exists $params{LICENSE};
	if ($params{AUTHOR} and ref($params{AUTHOR}) eq 'ARRAY' and $eumm_version < 6.5705) {
		$params{META_ADD}->{author}=$params{AUTHOR};
		$params{AUTHOR}=join(', ',@{$params{AUTHOR}});
	}
	if ($params{BUILD_REQUIRES} and $eumm_version < 6.5503) {
		#EUMM 6.5502 has problems with BUILD_REQUIRES
		$params{PREREQ_PM}={ %{$params{PREREQ_PM} || {}} , %{$params{BUILD_REQUIRES}} };
		delete $params{BUILD_REQUIRES};
	}
	delete $params{CONFIGURE_REQUIRES} if $eumm_version < 6.52;
	delete $params{MIN_PERL_VERSION} if $eumm_version < 6.48;
	delete $params{META_MERGE} if $eumm_version < 6.46;
	delete $params{META_ADD} if $eumm_version < 6.46;
	delete $params{LICENSE} if $eumm_version < 6.31;
	delete $params{AUTHOR} if $] < 5.005;
	delete $params{ABSTRACT_FROM} if $] < 5.005;
	delete $params{BINARY_LOCATION} if $] < 5.005;

	WriteMakefile(%params);
}

# Remove the Makefile dependency. Causes problems on a few systems.
sub MY::makefile { '' }
