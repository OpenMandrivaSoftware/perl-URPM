package URPM;

use strict;

#- pare from rpmlib db.
sub parse_pubkeys {
    my ($urpm, %options) = @_;
    my ($block, @l, $content);

    my $db = $options{db};
    $db ||= URPM::DB::open($options{root});

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
									 content => $content,
								       };
					  $block = undef;
					  $content = '';
				      } else {
					  $content .= $_;
				      }
				  }
			      }
			  }
		      })
}

#- parse an armored file and import in keys hash if the key does not already exists.
sub parse_armored_file {
    my ($urpm, $file, %options) = @_;
    my ($block, @l, $content);
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
		    push @l, $content;
		    $block = undef;
		    $content = '';
		} else {
		    $content .= $_;
		}
	    }
	}
    }
    close F or die "unable to parse armored file $file";

    #- check at least one key has been found.
    @l < 1 and die "no key found while parsing armored file";

    #- check if key has been found, remove from list.
    if ($options{only_unknown_keys}) {
	@l = grep {
	    my $found = 0;
	    foreach my $k (values %{$urpm->{keys} || {}}) {
		$k->{content} eq $_ and $found = 1, last;
	    }
	    !$found;
	} @l;
    }

    #- now return something (true) which reflect what should be found in keys.
    map { +{ content => $_ } } @l;
}

sub import_armored_file {
    my ($urpm, $file, %options) = @_;
    local (*F, $_);
    my $block = '';

    #- read armored file.
    open F, $file;
    while (<F>) {
	my $inside_block = /^-----BEGIN PGP PUBLIC KEY BLOCK-----$/ ... /^-----END PGP PUBLIC KEY BLOCK-----$/;
	if ($inside_block) {
	    $block .= $_;
	    if ($inside_block =~ /E/) {
		#- import key using the given database if any else the function will open the rpmdb itself.
		#- FIXME workaround for rpm 4.2 if the rpmdb is left opened, the keys content are sligtly
		#- modified by algorithms...
		URPM::import_pubkey(block => $block, db => $options{db}, root => $options{root})
		    or die "import of armored file failed";
		$block = '';
	    }
	}
    }
    close F or die "unable to parse armored file $file";
}

1;
