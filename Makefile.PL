
eval {use EV::MakeMaker qw(ev_args);};
warn 'ERROR! This module requries EV module instaled first. ' if($@);

use ExtUtils::MakeMaker;
my %options = (
  'TYPEMAPS' => [],
  'NAME' => 'HTTP::Server::EV',
  'VERSION' => '0.31',
  'OPTIMIZE' => ' -O2',
  'BUILD_REQUIRES' => { 
	'Time::HiRes'  => 0,
	'File::Copy'   => 0,
	'EV'		   => 0,
	'Guard'		   => 0,
	'AnyEvent::HTTP' => 0,
  },

);
WriteMakefile(ev_args(%options));

# Remove the Makefile dependency. Causes problems on a few systems.
sub MY::makefile { '' }