package URPM;

use strict;
use vars qw($VERSION @ISA);

require DynaLoader;

@ISA = qw(DynaLoader);
$VERSION = '0.02';

bootstrap URPM $VERSION;

sub new {
    my ($class) = @_;
    bless {
	   depslist      => [],
	   provides      => {},
	  }, $class;
}

#- relocate depslist array id to use only the most recent packages,
#- reorder info hashes to give only access to best packages.
sub relocate_depslist {
    my ($urpm, %options) = @_;
    my $relocated_entries = 0;

    #- reset names hash now, will be filled after.
    $urpm->{names} = {};

    foreach (@{$urpm->{depslist} || []}) {
	#- remove access to info if arch is incompatible and only
	#- take into account compatible arch to examine.
	#- set names hash by prefering first better version,
	#- then better release, then better arch.
	if ($_->is_arch_compat) {
	    my $p = $urpm->{names}{$_->name};
	    if ($p) {
		if ($_->compare_pkg($p) > 0) {
		    $urpm->{names}{$_->name} = $_;
		    ++$relocated_entries;
		}
	    } else {
		$urpm->{names}{$_->name} = $_;
	    }
	} elsif ($_->arch ne 'src') {
	    #- the package is removed, make it invisible (remove id).
	    my $id = $_->set_id;

	    #- the architecture is not compatible, this means the package is dropped.
	    #- we have to remove its reference in provides.
	    foreach ($_->provides) {
		delete $urpm->{provides}{$_}{$id};
	    }
	}
    }

    #- relocate id used in depslist array, delete id if the package
    #- should NOT be used.
    #- if no entries have been relocated, we can safely avoid this computation.
    if ($relocated_entries) {
	foreach (@{$urpm->{depslist}}) {
	    my $p = $urpm->{names}{$_->name} or next;
	    $_->set_id($p->id);
	}
    }

    $relocated_entries;
}

sub traverse {
    my ($urpm, $callback) = @_;

    if ($callback) {
	foreach (@{$urpm->{depslist} || []}) {
	    $callback->($_);
	}
    }

    scalar @{$urpm->{depslist} || []};
}

sub traverse_tag {
    my ($urpm, $tag, $names, $callback) = @_;
    my ($count, %names) = (0);

    if (@{$names || []}) {
	@names{@$names} = ();
	if ($tag eq 'name') {
	    foreach (@{$urpm->{depslist} || []}) {
		if (exists $names{$_->name}) {
		    $callback and $callback->($_);
		    ++$count;
		}
	    }
	} elsif ($tag eq 'whatprovides') {
	    foreach (@$names) {
		foreach (keys %{$urpm->{provides}{$_} || {}}) {
		    $callback and $callback->($urpm->{depslist}[$_]);
		    ++$count;
		}
	    }
	} elsif ($tag eq 'whatrequires') {
	    foreach (@{$urpm->{depslist} || []}) {
		if (grep { /^([^ \[]*)/ && exists $names{$1} } $_->requires) {
		    $callback and $callback->($_);
		    ++$count;
		}
	    }
	} elsif ($tag eq 'group') {
	    foreach (@{$urpm->{depslist} || []}) {
		if (exists $names{$_->group}) {
		    $callback and $callback->($_);
		    ++$count;
		}
	    }
	} elsif ($tag eq 'triggeredby' || $tag eq 'path') {
	    foreach (@{$urpm->{depslist} || []}) {
		if (grep { exists $names{$_} } $_->files) {
		    $callback and $callback->($_);
		    ++$count;
		}
	    }
	} else {
	    die "unknown tag";
	}
    }

    $count;
}
