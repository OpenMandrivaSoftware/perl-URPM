package URPM;

use strict;

#- parse from rpmlib db.
#-
#- side-effects: $urpm
sub parse_pubkeys {
    my ($urpm, %options) = @_;

    my $db = $options{db};
    $db ||= URPM::DB::open($options{root}) or die "Can't open RPM DB, aborting\n";
    my @keys = parse_pubkeys_($db);

    $urpm->{keys}{$_->{id}} = $_ foreach @keys;
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

    my $keyid = substr get_gpg_fingerprint($pubkey_file), 8;
    my ($kv) = grep { ($keyid eq $_->{id}) } @keys;
    my $imported;
    if (!$kv) {
	    if (!import_pubkey_file($db, $pubkey_file)) {
		#$urpm->{debug_URPM}("Couldn't import public key from ".$pubkey_file) if $urpm->{debug_URPM};
		$imported = 0;
	    } else {
		$imported = 1;
	    }
	    @keys = parse_pubkeys_($db);
	    ($kv) = grep { ($keyid eq $_->{id}) } @keys;
    }

    #- let the caller know about what has been found.
    #- this is an error if the key is not found.
    $o_callback and $o_callback->($kv?$kv->{id}:undef, $imported);
}

1;
