package URPM;

use strict;
use vars qw($VERSION @ISA);

require DynaLoader;

@ISA = qw(DynaLoader);
$VERSION = '0.09';

bootstrap URPM $VERSION;

sub new {
    my ($class) = @_;
    bless {
	   depslist      => [],
	   provides      => {},
	  }, $class;
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
