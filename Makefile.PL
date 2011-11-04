
eval {use EV::MakeMaker qw(ev_args);};
die 'ERROR! This module requries EV module.' if($@);

use ExtUtils::MakeMaker;
my %options = (
  'TYPEMAPS' => [],
  'NAME' => 'HTTP::Server::EV',
  'VERSION' => '0.1',
  'OPTIMIZE' => ' -O2',
  'BUILD_REQUIRES' => { 
	'Time::HiRes'  => 0,
	'File::Copy'   => 0
  },

);
WriteMakefile(ev_args(%options));

# Remove the Makefile dependency. Causes problems on a few systems.
sub MY::makefile { '' }