package URPM;

use strict;
use DynaLoader;

our @ISA = qw(DynaLoader);
our $VERSION = '0.83';

URPM->bootstrap($VERSION);

sub new {
    my ($class) = @_;
    bless {
	   depslist      => [],
	   provides      => {},
	  }, $class;
}

sub search {
    my ($urpm, $name, %options) = @_;
    my $best;

    #- tries other alternative if no strict searching.
    unless ($options{strict}) {
	if ($name =~ /^(.*)-([^\-]*)-([^\-]*)\.([^\.\-]*)$/) {
	    foreach (keys %{$urpm->{provides}{$1} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->fullname eq $name and return $pkg;
	    }
	}
	if ($name =~ /^(.*)-([^\-]*)-([^\-]*)$/) {
	    foreach (keys %{$urpm->{provides}{$1} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		my ($n, $v, $r, $a) = $pkg->fullname;
		$options{src} && $a eq 'src' || $pkg->is_arch_compat or next;
		"$n-$v-$r" eq $name or next;
		!$best || $pkg->compare_pkg($best) > 0 and $best = $pkg;
	    }
	    $best and return $best;
	}
	if ($name =~ /^(.*)-([^\-]*)$/) {
	    foreach (keys %{$urpm->{provides}{$1} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		my ($n, $v, undef, $a) = $pkg->fullname;
		$options{src} && $a eq 'src' || $pkg->is_arch_compat or next;
		"$n-$v" eq $name or next;
		!$best || $pkg->compare_pkg($best) > 0 and $best = $pkg;
	    }
	    $best and return $best;
	}
    }

    foreach (keys %{$urpm->{provides}{$name} || {}}) {
	my $pkg = $urpm->{depslist}[$_];
	my ($n, undef, undef, $a) = $pkg->fullname;
	$options{src} && $a eq 'src' || $pkg->is_arch_compat or next;
	$n eq $name or next;
	!$best || $pkg->compare_pkg($best) > 0 and $best = $pkg;
    }

    return $best;
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
    my $count = 0; 
    my %names;

    if (@{$names || []}) {
	if ($tag eq 'name') {
	    foreach my $n (@$names) {
		foreach (keys %{$urpm->{provides}{$n} || {}}) {
		    my $p = $urpm->{depslist}[$_];
		    $p->name eq $n or next;
		    $callback and $callback->($p);
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
	} else {
	    @names{@$names} = ();
	    if ($tag eq 'whatrequires') {
		foreach (@{$urpm->{depslist} || []}) {
		    if (grep { exists $names{$_} } $_->requires_nosense) {
			$callback and $callback->($_);
			++$count;
		    }
		}
	    } elsif ($tag eq 'whatconflicts') {
		foreach (@{$urpm->{depslist} || []}) {
		    if (grep { exists $names{$_} } $_->conflicts_nosense) {
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
		    if (grep { exists $names{$_} } $_->files, grep { m!^/! } $_->provides_nosense) {
			$callback and $callback->($_);
			++$count;
		    }
		}
	    } else {
		die "unknown tag";
	    }
	}
    }

    $count;
}

package URPM::Package;
our @ISA = qw(); # help perl_checker

package URPM::Transaction;
our @ISA = qw(); # help perl_checker

package URPM::DB;
our @ISA = qw(); # help perl_checker

1;
