package URPM;

use strict;

#- parse an armored file and import in keys hash if the key does not already exists.
sub parse_armored_file {
    my ($urpm, $file) = @_;
    my ($block, @l, $contents);
    local (*F, $_);

    #- read armored file.
    open F, $file;
    while (<F>) {
	chomp;
	$block ||= /^-----BEGIN PGP PUBLIC KEY BLOCK-----$/;
	if ($block) {
	    my $inside_block = /^$/ ... /^-----END PGP PUBLIC KEY BLOCK-----$/;
	    if ($inside_block > 1) {
		if ($inside_block =~ /E/) {
		    push @l, $contents;
		    $block = undef;
		    $contents = '';
		} else {
		    $contents .= $_;
		}
	    }
	}
    }
    close F or die "unable to parse armored file $file";

    #- check only one key has been found.
    @l > 1 and die "armored file contains more than one key";
    @l < 1 and die "no key found while parsing armored file";

    #- check if key has been found, remove from list.
    @l = grep {
	my $found = 0;
	foreach my $k (values %{$urpm->{keys}}) {
	    $k->{contents} eq $_ and $found = 1, last;
	}
	!$found;
    } @l;

    #- now return something (true) which reflect what should be found in keys.
    map { +{ contents => $_ } } @l;
}

#- pare from rpmdb.
sub parse_rpmdb_pubkeys {
    my ($urpm, $db) = @_;
    my ($block, @l, $contents);

    $db->traverse_tag('name', [ 'gpg-pubkey' ], sub {
			  my ($p) = @_;
			  my $s;
			  foreach (split "\n", $p->description) {
			      $block ||= /^-----BEGIN PGP PUBLIC KEY BLOCK-----$/;
			      if ($block) {
				  my $inside_block = /^$/ ... /^-----END PGP PUBLIC KEY BLOCK-----$/;
				  if ($inside_block > 1) {
				      if ($inside_block =~ /E/) {
					  $urpm->{keys}{$p->version} = { $p->summary =~ /^gpg\(\)$/ ? (name => $1) : @{[]},
									 id => $p->version,
									 contents => $contents,
								       };
					  $block = undef;
					  $contents = '';
				      } else {
					  $contents .= $_;
				      }
				  }
			      }
			  }
		      })
}

1;
