package URPM;

use strict;
use vars qw($VERSION @ISA);

require DynaLoader;

@ISA = qw(DynaLoader);
$VERSION = '0.80';

bootstrap URPM $VERSION;

sub new {
    my ($class) = @_;
    bless {
	   depslist      => [],
	   provides      => {},
	  }, $class;
}

sub search {
    my ($urpm, $name, %options) = @_;
    my $best = undef;

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

    foreach (keys %{$urpm->{provides}{$_} || {}}) {
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
	} elsif ($tag eq 'whatconflicts') {
	    foreach (@{$urpm->{depslist} || []}) {
		if (grep { /^([^ \[]*)/ && exists $names{$1} } $_->conflicts) {
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
		if (grep { exists $names{$_} } $_->files, grep { /^\// } $_->provides_nosense) {
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
