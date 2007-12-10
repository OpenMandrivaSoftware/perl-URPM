package URPM;

use strict;

#- compare keys to avoid glitches introduced during the importation where
#- some characters may be modified on the fly by rpm --import...
sub compare_pubkeys {
    my ($a, $b) = @_;
    my $diff = 0;
    my @a = unpack "C*", $a->{content};
    my @b = unpack "C*", $b->{content};

    my %options;
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
    my (undef, $file) = @_;
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

#- parse from rpmlib db.
#-
#- side-effects: $urpm
sub parse_pubkeys {
    my ($urpm, %options) = @_;

    my $db = $options{db};
    $db ||= URPM::DB::open($options{root}) or die "Can't open RPM DB, aborting\n";
    my @keys = parse_pubkeys_($db);

    $urpm->{keys}{$_->id} = $_ foreach @keys;
}
    
#- side-effects: none
sub parse_pubkeys_ {
    my ($db) = @_;
    
    my ($block, $content);
    my %keys;

    $db->traverse_tag('name', [ 'gpg-pubkey' ], sub {
	    my ($p) = @_;
	    foreach (split "\n", $p->description) {
		$block ||= /^-----BEGIN PGP PUBLIC KEY BLOCK-----$/;
		if ($block) {
		    my $inside_block = /^$/ ... /^-----END PGP PUBLIC KEY BLOCK-----$/;
		    if ($inside_block > 1) {
			if ($inside_block =~ /E/) {
			    $keys{$p->version} = {
				$p->summary =~ /^gpg\((.*)\)$/ ? (name => $1) : @{[]},
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
	});

    values %keys;
}

#- obsoleted
sub import_needed_pubkeys {
    warn "import_needed_pubkeys prototype has changed, please give a file directly\n";
    return;
}

#- import pubkeys only if it is needed.
sub import_needed_pubkeys_from_file {
    my ($db, $pubkey_file, $o_callback) = @_;

    my @keys = parse_pubkeys_($db);

    my $find_key = sub {
	my ($k) = @_;
	my ($kv) = grep { compare_pubkeys($k, $_) == 0 } @keys;
	$kv && $kv->{id};
    };

    foreach my $k (parse_armored_file(undef, $pubkey_file)) {
	my $imported;
	my $id = $find_key->($k);
	if (!$id) {
	    $imported = 1;
	    import_pubkey_file($db, $pubkey_file);
	    @keys = parse_pubkeys_($db);
	    $id = $find_key->($k);
	}
	#- let the caller know about what has been found.
	#- this is an error if the key is not found.
	$o_callback and $o_callback->($id, $imported);
    }
}

1;
