package HTTP::Server::EV::MultipartFile;
use File::Copy;
use strict;
our $VERSION = '0.1';

=head1 NAME

	HTTP::Server::EV::MultipartFile - represents file received by L<HTTP::Server::EV>

=cut


sub size {shift->{size}};
sub name {shift->{name}};
sub path {shift->{path}};


=head1 FILE PARAMETERS

=over

=item $file->size or $file->{size} 

Filesize in bytes

=item $file->name or $file->{name}

Filename received in http request

=item $file->path or $file->{path}

Path to tmp file. You don`t need to use this. Use $file->save() instead

=back

=head1 METHODS

=head2 $file->fh;

Return filehandle opened to reading. Die on error

=cut



sub fh {
	my $self = shift;
	
	unless($self->{fh}){
		open ($self->{fh}, '<', $self->{path}) or die 'Can`t open tmp file '.$self->{path};
		binmode $self->{fh};
	}
	
	return $self->{fh};
}


=head2 $file->save($path);

Save received file to $path. Just moves file from tmp dir to $path if possible. Dies on error

=cut


sub save {
	my ($self, $dest) = @_;
	close delete $self->{fh} if $self->{fh};
	
	if($self->{moved}){
		copy($self->{path}, $dest ) or die 'Can`t save tmp file '.$self->{path}.' to '.$dest;
	}else{
		move($self->{path}, $dest ) or die 'Can`t save tmp file '.$self->{path}.' to '.$dest;
		$self->{path} = $dest;
		$self->{moved} = 1;
	}
}


=head2 $file->del;

Delete file from tmp directory. You don`t need to use this method, L<HTTP::Server::EV::CGI> calls it on all request files on DESTROY

=cut


sub del {
	my $self = shift;
	
	close $self->{fh} if $self->{fh};
	unlink $self->{path} unless $self->{moved};
}


1;