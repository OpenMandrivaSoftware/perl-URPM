package URPM;

use strict;

#- compare keys to avoid glitches introduced during the importation where
#- some characters may be modified on the fly by rpm --import...
sub compare_pubkeys {
    my ($a, $b, %options) = @_;
    my $diff = 0;
    my @a = unpack "C*", $a->{content};
    my @b = unpack "C*", $b->{content};

    #- default options to use.
    $options{start} ||= 0;
    $options{end} ||= @a < @b ? scalar(@b) : scalar(@a);
    $options{diff} ||= 1;

    #- check element one by one, count all difference (do not work well if elements
    #- have been inserted/deleted).
    foreach ($options{start} .. $options{end}) {
	$a[$_] != $b[$_] and ++$diff;
    }

    #- diff options give level to consider the key equal (a character is not always the same).
    $diff <= $options{diff} ? 0 : $diff;
}

#- parse an armored file and import in keys hash if the key does not already exists.
sub parse_armored_file {
    my ($urpm, $file, %options) = @_;
    my ($block, $content, @l);

    #- check if an already opened file has been given directly.
    unless (ref $file) {
	my $F;
	open $F, $file or return ();
	$file = $F;
    }

    #- read armored file.
    local $_;
    while (<$file>) {
	my $inside_block = /^-----BEGIN PGP PUBLIC KEY BLOCK-----$/ ... /^-----END PGP PUBLIC KEY BLOCK-----$/;
	if ($inside_block) {
	    $block .= $_;
	    if ($inside_block =~ /E/) {
		#- block is needed to import the key if needed.
		push @l, { block => $block, content => $content };
		$block = $content = undef;
	    } else {
		#- compute content for finding the right key.
		chomp;
		/^$/ and $content = '';
		defined $content and $content .= $_;
	    }
	}
    }
    @l;
}

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
					  $urpm->{keys}{$p->version} = { $p->summary =~ /^gpg\((.*)\)$/ ? (name => $1) : @{[]},
									 id => $p->version,
									 content => $content,
									 block => $p->description,
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

#- import pubkeys only if it is needed.
sub import_needed_pubkeys {
    my ($urpm, $l, %options) = @_;
    my $block = '';

    #- use the same database handle to avoid re-opening multiple times the database.
    my $db = $options{db};
    $db ||= URPM::DB::open($options{root}, 1);

    #- assume $l is a reference to an array containing all the keys to import
    #- if needed.
    foreach my $k (@{$l || []}) {
	my ($id, $imported);
	foreach my $kv (values %{$urpm->{keys} || {}}) {
	    compare_pubkeys($k, $kv, %options) == 0 and $id = $kv->{id}, last;
	}
	unless ($id) {
	    $imported = 1;
	    import_pubkey(block => $k->{block}, db => $db);
	    $urpm->parse_pubkeys(db => $db);
	    foreach my $kv (values %{$urpm->{keys} || {}}) {
		compare_pubkeys($k, $kv, %options) == 0 and $id = $kv->{id}, last;
	    }
	}
	#- let the caller know about what has been found.
	#- this is an error if the key is not found.
	$options{callback} and $options{callback}->($urpm, $db, $k, $id, $imported, %options);
    }
}

1;
