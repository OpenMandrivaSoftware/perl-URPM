package URPM;
#package URPM::Resolve;
#use URPM;

# $Id$

use strict;
use Config;

sub min { my $n = shift; $_ < $n and $n = $_ foreach @_; $n }
sub uniq { my %l; $l{$_} = 1 foreach @_; grep { delete $l{$_} } @_ }

sub property2name {
    $_[0] =~ /^([^\s\[]*)/ && $1;
}
sub property2name_range {
    $_[0] =~ /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/;
}
sub property2name_op_version {
    $_[0] =~ /^([^\s\[]*)(?:\[\*\])?\s*\[?([^\s\]]*)\s*([^\s\]]*)/;
}

#- Find candidates packages from a require string (or id).
#- Takes care of direct choices using the '|' separator.
#-
#- side-effects: none
sub find_candidate_packages_ {
    my ($urpm, $id_prop, $o_rejected) = @_;
    my @packages;

    foreach (split /\|/, $id_prop) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->flag_skip and next;
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    $o_rejected && exists $o_rejected->{$pkg->fullname} and next;
	    push @packages, $pkg;
	} elsif (my $name = property2name($_)) {
	    my $property = $_;
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->flag_skip and next;
		$pkg->is_arch_compat or next;
		$o_rejected && exists $o_rejected->{$pkg->fullname} and next;
		#- check if at least one provide of the package overlap the property.
		!$urpm->{provides}{$name}{$_} || $pkg->provides_overlap($property, 1)
		    and push @packages, $pkg;
	    }
	}
    }
    @packages;
}
#- side-effects: none
sub find_candidate_packages {
    my ($urpm, $id_prop, $o_rejected) = @_;

    my %packages;
    foreach (find_candidate_packages_($urpm, $id_prop, $o_rejected)) {
	push @{$packages{$_->name}}, $_;
    }
    \%packages;
}

sub get_installed_arch {
    my ($db, $n) = @_;
    my $arch;
    $db->traverse_tag('name', [ $n ], sub { $arch = $_[0]->arch });
    $arch;
}

my %installed_arch;
#- side-effects: none (but uses a cache)
sub strict_arch_check {
    my ($db, $pkg) = @_;
    if ($pkg->arch ne 'src' && $pkg->arch ne 'noarch') {
	my $n = $pkg->name;
	defined $installed_arch{$n} or $installed_arch{$n} = get_installed_arch($db, $n);
	if ($installed_arch{$n} && $installed_arch{$n} ne 'noarch') {
	    $pkg->arch eq $installed_arch{$n} or return;
	}
    }
    1;
}

# deprecated function name
sub find_chosen_packages { &find_required_package }

#- side-effects: flag_install, flag_upgrade (and strict_arch_check cache)
sub find_required_package {
    my ($urpm, $db, $state, $id_prop) = @_;
    my %packages;
    my $strict_arch = defined $urpm->{options}{'strict-arch'} ? $urpm->{options}{'strict-arch'} : $Config{archname} =~ /x86_64|sparc64|ppc64/;

    my $may_add_to_packages = sub {
	my ($pkg) = @_;

	if (my $p = $packages{$pkg->name}) {
	    $pkg->flag_requested > $p->flag_requested ||
	      $pkg->flag_requested == $p->flag_requested && $pkg->compare_pkg($p) > 0 and $packages{$pkg->name} = $pkg;
	} else {
	    $packages{$pkg->name} = $pkg;
	}
    };

    #- search for possible packages, try to be as fast as possible, backtrack can be longer.
    foreach (split /\|/, $id_prop) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    $pkg->flag_skip || $state->{rejected}{$pkg->fullname} and next;
	    #- determine if this package is better than a possibly previously chosen package.
	    $pkg->flag_selected || exists $state->{selected}{$pkg->id} and return [$pkg];
	    !$strict_arch || strict_arch_check($db, $pkg) or next;
	    $may_add_to_packages->($pkg);
	} elsif (my $name = property2name($_)) {
	    my $property = $_;
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->is_arch_compat or next;
		$pkg->flag_skip || $state->{rejected}{$pkg->fullname} and next;
		#- check if at least one provide of the package overlaps the property
		if (!$urpm->{provides}{$name}{$_} || $pkg->provides_overlap($property)) {
		    #- determine if this package is better than a possibly previously chosen package.
		    $pkg->flag_selected || exists $state->{selected}{$pkg->id} and return [$pkg];
		    !$strict_arch || strict_arch_check($db, $pkg) or next;
		    $may_add_to_packages->($pkg);		    
		}
	    }
	}
    }
    my @packages = values %packages;

    if (@packages > 1) {
	#- packages should be preferred if one of their provides is referenced
	#- in the "requested" hash, or if the package itself is requested (or
	#- required).
	#- If there is no preference, choose the first one by default (higher
	#- probability of being chosen) and ask the user.
	#- Packages with more compatibles architectures are always preferred.
	#- Puts the results in @chosen. Other are left unordered.
	foreach my $pkg (@packages) {
	    _set_flag_installed_and_upgrade_if_no_newer($db, $pkg);
	}

	_find_required_package__sort($urpm, $db, \@packages);
    } else {
	\@packages;
    }
}

# nb: _set_flag_installed_and_upgrade_if_no_newer must be done on $packages
sub _find_required_package__sort {
    my ($urpm, $db, $packages) = @_;

	my ($best, @other) = sort { 
	    $a->[1] <=> $b->[1] #- we want the lowest (ie preferred arch)
	      || $b->[2] <=> $a->[2]; #- and the higher
	} map {
	    my $score = 0;
	    $score += 2 if $_->flag_requested;
	    $score += $_->flag_upgrade ? 1 : -1 if $_->flag_installed;
	    [ $_, $_->is_arch_compat, $score ];
	} @$packages;

	my @chosen_with_score = ($best, grep { $_->[1] == $best->[1] && $_->[2] == $best->[2] } @other);
	my @chosen = map { $_->[0] } @chosen_with_score;

	#- return immediately if there is only one chosen package
	if (@chosen == 1) { return \@chosen }

	#- if several packages were selected to match a requested installation,
	#- and if --more-choices wasn't given, trim the choices to the first one.
	if (!$urpm->{options}{morechoices} && $chosen_with_score[0][2] == 3) {
	    return [ $chosen[0] ];
	}

	#- prefer kernel-source-stripped over kernel-source
	{
	    my (@k_chosen, $stripped_kernel);
	    foreach my $p (@chosen) {
		if ($p->name =~ /^kernel-source-stripped/) { #- fast, but unportable
		    unshift @k_chosen, $p;
		    $stripped_kernel = 1;
		} else {
		    push @k_chosen, $p;
		}
	    }
	    return \@k_chosen if $stripped_kernel;
	}

    if ($urpm->{media}) {
	@chosen_with_score = sort {
	    $a->[2] != $b->[2] ? 
	       $a->[0]->id <=> $b->[0]->id : 
	       $b->[1] <=> $a->[1] || $b->[0]->compare_pkg($a->[0]);
	} map { [ $_, _score_for_locales($urpm, $db, $_), pkg2media($urpm->{media}, $_) ] } @chosen;
    } else {
	$urpm->{debug_URPM}("can't sort choices by media") if $urpm->{debug_URPM};
	@chosen_with_score = sort {
	    $b->[1] <=> $a->[1] ||
	      $b->[0]->compare_pkg($a->[0]) || $a->[0]->id <=> $b->[0]->id;
	} map { [ $_, _score_for_locales($urpm, $db, $_) ] } @chosen;
    }
    if (!$urpm->{options}{morechoices}) {
	if (my @valid_locales = grep { $_->[1] } @chosen_with_score) {
	    #- get rid of invalid locales
	    @chosen_with_score = @valid_locales;
	}
    }
    # propose to select all packages for installed locales
    my @prefered = grep { $_->[1] == 3 } @chosen_with_score;

    [ map { $_->[0] } @chosen_with_score ], [ map { $_->[0] } @prefered ];
}

#- Packages that require locales-xxx when the corresponding locales are
#- already installed should be preferred over packages that require locales
#- which are not installed.
sub _score_for_locales {
    my ($urpm, $db, $pkg) = @_;

    my @r = $pkg->requires_nosense;

    if (my ($specific_locales) = grep { /locales-(?!en)/ } @r) {
	if ((grep { $urpm->{depslist}[$_]->flag_available } keys %{$urpm->{provides}{$specific_locales}}) > 0 ||
	      $db->traverse_tag('name', [ $specific_locales ], undef) > 0) {
	      3; # good locale
	  } else {
	      0; # bad locale
	  }
    } elsif (grep { /locales-en/ } @r) {
	2; # 
    } else {
	1;
    }
}

#- side-effects: $properties
#-   + those of backtrack_selected ($state->{backtrack}, $state->{rejected}, $state->{selected}, $state->{whatrequires}, flag_requested, flag_required)
sub _choose_required {
    my ($urpm, $db, $state, $dep, $properties, %options) = @_;

    #- take the best choice possible.
    my ($chosen, $prefered) = find_required_package($urpm, $db, $state, $dep->{required});

    #- If no choice is found, this means that nothing can be possibly selected
    #- according to $dep, so we need to retry the selection, allowing all
    #- packages that conflict or anything similar to see which strategy can be
    #- tried. Backtracking is used to avoid trying multiple times the same
    #- packages. If multiple packages are possible, simply ask the user which
    #- one to choose; else take the first one available.
    if (!@$chosen) {
	$urpm->{debug_URPM}("no packages match " . _dep_to_name($urpm, $dep) . " (it may be in skip.list)") if $urpm->{debug_URPM};
	unshift @$properties, backtrack_selected($urpm, $db, $state, $dep, %options);
	return; #- backtrack code choose to continue with same package or completely new strategy.
    } elsif ($options{callback_choices} && @$chosen > 1) {
	my @l = grep { ref $_ } $options{callback_choices}->($urpm, $db, $state, $chosen, _dep_to_name($urpm, $dep), $prefered);
	$urpm->{debug_URPM}("replacing " . _dep_to_name($urpm, $dep) . " with " . 
			      join(' ', map { $_->name } @l)) if $urpm->{debug_URPM};
	unshift @$properties, map {
	    +{
		required => $_->id,
		_choices => $dep->{required},
		exists $dep->{from} ? (from => $dep->{from}) : @{[]},
		exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
	    };
	} @l;
	return; #- always redo according to choices.
    }

    #- now do the real work, select the package.
    my $pkg = shift @$chosen;
    if ($urpm->{debug_URPM} && $pkg->name ne _dep_to_name($urpm, $dep)) {
	$urpm->{debug_URPM}("chosen " . $pkg->fullname . " for " . _dep_to_name($urpm, $dep));
	@$chosen and $urpm->{debug_URPM}("  (it could also have chosen " . join(' ', map { scalar $_->fullname } @$chosen));
    }

    $pkg;
}

sub find(&@) {
    my $f = shift;
    $f->($_) and return $_ foreach @_;
    undef;
}
sub pkg2media {
   my ($mediums, $p) = @_; 
   my $id = $p->id;
   find { $id >= $_->{start} && $id <= $_->{end} } @$mediums;
}

sub whatrequires {
    my ($urpm, $state, $property_name) = @_;

    map { $urpm->{depslist}[$_] } whatrequires_id($state, $property_name);
}
sub whatrequires_id {
    my ($state, $property_name) = @_;

    keys %{$state->{whatrequires}{$property_name} || {}};
}

#- return unresolved requires of a package (a new one or an existing one).
#-
#- side-effects: none (but uses a $state->{cached_installed})
sub unsatisfied_requires {
    my ($urpm, $db, $state, $pkg, %options) = @_;
    my %unsatisfied;

    #- all requires should be satisfied according to selected packages or installed packages,
    #- or the package itself.
  REQUIRES: foreach my $prop ($pkg->requires) {
	my ($n, $s) = property2name_range($prop) or next;

	if (defined $options{name} && $n ne $options{name}) {
	    #- allow filtering on a given name (to speed up some search).
	} elsif (exists $unsatisfied{$prop}) {
	    #- avoid recomputing the same all the time.
	} else {
	    #- check for installed packages in the installed cache.
	    foreach (keys %{$state->{cached_installed}{$n} || {}}) {
		exists $state->{rejected}{$_} and next;
		next REQUIRES;
	    }

	    #- check on the selected package if a provide is satisfying the resolution (need to do the ops).
	    foreach (grep { exists $state->{selected}{$_} } keys %{$urpm->{provides}{$n} || {}}) {
		my $p = $urpm->{depslist}[$_];
		!$urpm->{provides}{$n}{$_} || $p->provides_overlap($prop, 1) and next REQUIRES;
	    }

	    #- check if the package itself provides what is necessary.
	    $pkg->provides_overlap($prop) and next REQUIRES;

	    #- check on installed system if a package which is not obsoleted is satisfying the require.
	    my $satisfied = 0;
	    if ($n =~ m!^/!) {
		$db->traverse_tag('path', [ $n ], sub {
		    my ($p) = @_;
		    exists $state->{rejected}{$p->fullname} and return;
		    $state->{cached_installed}{$n}{$p->fullname} = undef;
		    ++$satisfied;
		});
	    } else {
		$db->traverse_tag('whatprovides', [ $n ], sub {
		    my ($p) = @_;
		    exists $state->{rejected}{$p->fullname} and return;
		    foreach ($p->provides) {
			if (my ($pn, $ps) = property2name_range($_)) {
			    $ps or $state->{cached_installed}{$pn}{$p->fullname} = undef;
			    $pn eq $n or next;
			    ranges_overlap($ps, $s, 1) and ++$satisfied;
			}
		    }
		});
	    }
	    #- if nothing can be done, the require should be resolved.
	    $satisfied or $unsatisfied{$prop} = undef;
	}
    }

    keys %unsatisfied;
}

#- this function is "suggests vs requires" safe:
#-   'whatrequires' will give both requires & suggests, but unsatisfied_requires
#-   will check $p->requires and so filter out suggests

#- side-effects: only those done by $do
sub with_db_unsatisfied_requires {
    my ($urpm, $db, $state, $name, $do) = @_;

    $db->traverse_tag('whatrequires', [ $name ], sub {
	my ($p) = @_;
	if (my @l = unsatisfied_requires($urpm, $db, $state, $p, name => $name)) {
	    $urpm->{debug_URPM}($p->fullname . " is conflicting because of unsatisfied @l") if $urpm->{debug_URPM};
	    $do->($p, @l);
	}
    });
}

# used when a require is not available
#
#- side-effects: $state->{backtrack}, $state->{rejected}, $state->{selected}
#-   + those of disable_selected_and_unrequested_dependencies ($state->{whatrequires}, flag_requested, flag_required)
#-   + those of _set_rejected_from ($state->{rejected})
#-   + those of resolve_rejected_ ($state->{rejected})
sub backtrack_selected {
    my ($urpm, $db, $state, $dep, %options) = @_;

    if (defined $dep->{required}) {
	#- avoid deadlock here...
	if (exists $state->{backtrack}{deadlock}{$dep->{required}}) {
	    $options{keep} = 1; #- force keeping package to that backtrack is doing something.
	} else {
	    $state->{backtrack}{deadlock}{$dep->{required}} = undef;

	    #- search for all possible packages, first is to try the selection, then if it is
	    #- impossible, backtrack the origin.
	    my @packages = find_candidate_packages_($urpm, $dep->{required});

	    foreach (@packages) {
		    #- avoid dead loop.
		    exists $state->{backtrack}{selected}{$_->id} and next;
		    #- a package if found is problably rejected or there is a problem.
		    if ($state->{rejected}{$_->fullname}) {
			    #- keep in mind a backtrack has happening here...
			    $state->{rejected}{$_->fullname}{backtrack} ||=
			      { exists $dep->{promote} ? (promote => [ $dep->{promote} ]) : @{[]},
				exists $dep->{psel} ? (psel => $dep->{psel}) : @{[]},
			      };
			    #- backtrack callback should return a strictly positive value if the selection of the new
			    #- package is prefered over the currently selected package.
			    next;
		    }
		    $state->{backtrack}{selected}{$_->id} = undef;

		    #- in such case, we need to drop the problem caused so that rejected condition is removed.
		    #- if this is not possible, the next backtrack on the same package will be refused above.
		    my @l = map { $urpm->search($_, strict_fullname => 1) }
		      keys %{($state->{rejected}{$_->fullname} || {})->{closure}};

		    disable_selected_and_unrequested_dependencies($urpm, $db, $state, @l);

		    return { required => $_->id,
			     exists $dep->{from} ? (from => $dep->{from}) : @{[]},
			     exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
			   };
	    }
	}
    }

    if (defined $dep->{from}) {
	if ($options{nodeps}) {
	    #- try to keep unsatisfied dependencies in requested.
	    if ($dep->{required} && exists $state->{selected}{$dep->{from}->id}) {
		push @{$state->{selected}{$dep->{from}->id}{unsatisfied}}, $dep->{required};
	    }
	} else {
	    #- at this point, dep cannot be resolved, this means we need to disable
	    #- all selection tree, re-enabling removed and obsoleted packages as well.
	    unless (exists $state->{rejected}{$dep->{from}->fullname}) {
		#- package is not currently rejected, compute the closure now.
		my @l = disable_selected_and_unrequested_dependencies($urpm, $db, $state, $dep->{from});
		foreach (@l) {
		    #- disable all these packages in order to avoid selecting them again.
		    _set_rejected_from($state, $_, $dep->{from}); 
		}
	    }
	    #- the package is already rejected, we assume we can add another reason here!
	    $urpm->{debug_URPM}("adding a reason to already rejected package " . $dep->{from}->fullname . ": unsatisfied " . $dep->{required}) if $urpm->{debug_URPM};
	    
	    push @{$state->{rejected}{$dep->{from}->fullname}{backtrack}{unsatisfied}}, $dep->{required};
	}
    }

    my @properties;
    if (defined $dep->{psel}) {
	if ($options{keep}) {
	    backtrack_selected_psel_keep($urpm, $db, $state, $dep->{psel}, $dep->{keep});

	    #- the package is already rejected, we assume we can add another reason here!
	    defined $dep->{promote} and push @{$state->{rejected}{$dep->{psel}->fullname}{backtrack}{promote}}, $dep->{promote};
	} else {
	    #- the backtrack need to examine diff_provides promotion on $n.
	    with_db_unsatisfied_requires($urpm, $db, $state, $dep->{promote}, sub {
				      my ($p, @l) = @_;
				      #- typically a redo of the diff_provides code should be applied...
				      resolve_rejected_($urpm, $db, $state, $p, \@properties,
							      removed => 1,
							      from => $dep->{psel},
							      why => { unsatisfied => \@l });
			      });
	}
    }

    #- some packages may have been removed because of selection of this one.
    #- the rejected flags should have been cleaned by disable_selected above.
    @properties;
}

#- side-effects:
#-   + those of _set_rejected_from ($state->{rejected})
#-   + those of disable_selected_and_unrequested_dependencies ($state->{selected}, $state->{whatrequires}, flag_requested, flag_required)
sub backtrack_selected_psel_keep {
    my ($urpm, $db, $state, $psel, $keep) = @_;

    #- we shouldn't try to remove packages, so psel which leads to this need to be unselected.
    unless (exists $state->{rejected}{$psel->fullname}) {
	#- package is not currently rejected, compute the closure now.
	my @l = disable_selected_and_unrequested_dependencies($urpm, $db, $state, $psel);
	foreach (@l) {
	    #- disable all these packages in order to avoid selecting them again.
	    _set_rejected_from($state, $_, $psel);
	}
    }
    #- to simplify, a reference to list or standalone elements may be set in keep.
    $keep and push @{$state->{rejected}{$psel->fullname}{backtrack}{keep}}, @$keep;
}

#- side-effects: $state->{rejected}
sub _remove_all_rejected_from {
    my ($state, $from_fullname) = @_;

    grep {
	_remove_rejected_from($state, $_, $from_fullname);
    } keys %{$state->{rejected}};
}

#- side-effects: $state->{rejected}
sub _remove_rejected_from {
    my ($state, $fullname, $from_fullname) = @_;

    my $rv = $state->{rejected}{$fullname} or return;
    exists $rv->{closure}{$from_fullname} or return;
    delete $rv->{closure}{$from_fullname};
    if (%{$rv->{closure}}) {
	0;
    } else {
	delete $state->{rejected}{$fullname};
	1;
    }
}

#- useful to reject packages in advance
#- eg when selecting "a" which conflict with "b", ensure we won't select "b"
#- but it's somewhat dangerous because it's sometimes called on installed packages,
#- and in that case, a real resolve_rejected_ must be done
#- (that's why set_rejected ignores the effect of _set_rejected_from)
#-
#- side-effects: $state->{rejected}
sub _set_rejected_from {
    my ($state, $pkg, $from_pkg) = @_;

    $pkg->fullname ne $from_pkg->fullname or return;

    $state->{rejected}{$pkg->fullname}{closure}{$from_pkg->fullname} ||= undef;
}

#- side-effects: $state->{rejected}
sub set_rejected {
    my ($urpm, $state, $pkg, %options) = @_;

    my $rv = $state->{rejected}{$pkg->fullname} ||= {};

    my $newly_rejected = !exists $rv->{size};

    if ($newly_rejected) {
	$urpm->{debug_URPM}("set_rejected: " . $pkg->fullname) if $urpm->{debug_URPM};
	#- keep track of size of package which are finally removed.
	$rv->{size} = $pkg->size;
    }

    #- keep track of what causes closure.
    if ($options{from}) {
	my $closure = $rv->{closure}{scalar $options{from}->fullname} ||= {};
	if (my $l = delete $options{why}{unsatisfied}) {
	    my $unsatisfied = $closure->{unsatisfied} ||= [];
	    @$unsatisfied = uniq(@$unsatisfied, @$l);
	}
	$closure->{$_} = $options{why}{$_} foreach keys %{$options{why}};
    }

    #- set removed and obsoleted level.
    foreach (qw(removed obsoleted)) {
	$options{$_} && (! exists $rv->{$_} || $options{$_} <= $rv->{$_})
	  and $rv->{$_} = $options{$_};
    }

    $newly_rejected;
}

#- see resolve_rejected_ below
sub resolve_rejected {
    my ($urpm, $db, $state, $pkg, %options) = @_;
    resolve_rejected_($urpm, $db, $state, $pkg, $options{unsatisfied}, %options);
}

#- close rejected (as urpme previously) for package to be removable without error.
#-
#- side-effects: $properties
#-   + those of set_rejected ($state->{rejected})
sub resolve_rejected_ {
    my ($urpm, $db, $state, $pkg, $properties, %options) = @_;

    $urpm->{debug_URPM}("resolve_rejected: " . $pkg->fullname) if $urpm->{debug_URPM};

    #- check if the package has already been asked to be rejected (removed or obsoleted).
    #- this means only add the new reason and return.
    my $newly_rejected = set_rejected($urpm, $state, $pkg, %options);

    $newly_rejected or return;

	my @pkgs_todo = $pkg;

	while (my $cp = shift @pkgs_todo) {
	    #- close what requires this property, but check with selected package requiring old properties.
	    foreach my $n ($cp->provides_nosense) {
		    foreach my $pkg (whatrequires($urpm, $state, $n)) {
			if (my @l = unsatisfied_requires($urpm, $db, $state, $pkg, name => $n)) {
			    #- a selected package requires something that is no more available
			    #- and should be tried to be re-selected if possible.
			    if ($properties) {
				push @$properties, map { 
				    { required => $_, rejected => scalar $pkg->fullname }; # rejected is only there for debugging purpose (??)
				} @l;
			    }
			}
		    }
		    with_db_unsatisfied_requires($urpm, $db, $state, $n, sub {
			    my ($p, @l) = @_;

			    my $newly_rejected = set_rejected($urpm, $state, $p, %options, 
						  from => $pkg, 
						  why => { unsatisfied => \@l });

			    #- continue the closure unless already examined.
			    $newly_rejected or return;

			    $p->pack_header; #- need to pack else package is no longer visible...
			    push @pkgs_todo, $p;
		    });
	    }
	}
}

# see resolve_requested__no_suggests below for information about usage
sub resolve_requested {
    my ($urpm, $db, $state, $requested, %options) = @_;

    my @selected = resolve_requested__no_suggests($urpm, $db, $state, $requested, %options);

    if (!$options{no_suggests}) {
	my @todo = @selected;
	while (@todo) {
	    my $pkg = shift @todo;
	    my %suggests = map { $_ => 1 } $pkg->suggests or next;

	    #- do not install a package that has already been suggested
	    $db->traverse_tag('name', [ $pkg->name ], sub {
		my ($p) = @_;
		delete $suggests{$_} foreach $p->suggests;
	    });

	    %suggests or next;

	    $urpm->{debug_URPM}("requested " . join(', ', keys %suggests) . " suggested by " . $pkg->fullname) if $urpm->{debug_URPM};
	    
	    my %new_requested = map { $_ => undef } keys %suggests;
	    my @new_selected = resolve_requested__no_suggests($urpm, $db, $state, \%new_requested, %options);
	    $state->{selected}{$_->id}{suggested} = 1 foreach @new_selected;
	    push @selected, @new_selected;
	    push @todo, @new_selected;
	}
    }
    @selected;
}

#- Resolve dependencies of requested packages; keep resolution state to
#- speed up process.
#- A requested package is marked to be installed; once done, an upgrade flag or
#- an installed flag is set according to the needs of the installation of this
#- package.
#- Other required packages will have a required flag set along with an upgrade
#- flag or an installed flag.
#- Base flag should always be "installed" or "upgraded".
#- The following options are recognized :
#-   callback_choices : subroutine to be called to ask the user to choose
#-     between several possible packages. Returns an array of URPM::Package
#-     objects, or an empty list eventually.
#-   keep :
#-   nodeps :
#-
#- side-effects: flag_requested
#-   + those of resolve_requested__no_suggests_
sub resolve_requested__no_suggests {
    my ($urpm, $db, $state, $requested, %options) = @_;

    foreach (keys %$requested) {
	#- keep track of requested packages by propating the flag.
	foreach (find_candidate_packages_($urpm, $_)) {
	    $_->set_flag_requested;
	}
    }

    resolve_requested__no_suggests_($urpm, $db, $state, $requested, %options);
}

# same as resolve_requested__no_suggests, but do not modify requested_flag
#-
#- side-effects: $state->{selected}, flag_required, flag_installed, flag_upgrade
#-   + those of backtrack_selected     (flag_requested, $state->{rejected}, $state->{whatrequires}, $state->{backtrack})
#-   + those of _compute_diff_provides (flag_requested, $state->{rejected}, $state->{whatrequires}, $state->{oldpackage}, $state->{unselected_uninstalled})
#-   + those of _handle_conflicts      ($state->{rejected})
#-   + those of _handle_provides_overlap ($state->{rejected})
#-   + those of backtrack_selected_psel_keep (flag_requested, $state->{whatrequires})
#-   + those of _handle_diff_provides  (flag_requested, $state->{rejected}, $state->{whatrequires})
sub resolve_requested__no_suggests_ {
    my ($urpm, $db, $state, $requested, %options) = @_;

    my @properties = map {
	{ required => $_, requested => $requested->{$_} };
    } keys %$requested;

    my (@diff_provides, @selected);

    #- for each dep property evaluated, examine which package will be obsoleted on $db,
    #- then examine provides that will be removed (which need to be satisfied by another
    #- package present or by a new package to upgrade), then requires not satisfied and
    #- finally conflicts that will force a new upgrade or a remove.
    do {
	while (my $dep = shift @properties) {
	    #- we need to avoid selecting packages if the source has been disabled.
	    if (exists $dep->{from}) {
		exists $state->{selected}{$dep->{from}->id} or next;
	    }

	    my $pkg = _choose_required($urpm, $db, $state, $dep, \@properties, %options) or next;

	    !$pkg || exists $state->{selected}{$pkg->id} and next;

	    if ($pkg->arch eq 'src') {
		$pkg->set_flag_upgrade;
	    } else {
		_set_flag_installed_and_upgrade_if_no_newer($db, $pkg);

		if ($pkg->flag_installed && !$pkg->flag_upgrade) {
		    _no_more_recent_installed_and_providing($urpm, $db, $pkg, $dep->{required}) or next;
		}
	    }

	    #- keep in mind the package has be selected, remove the entry in requested input hash,
	    #- this means required dependencies have undef value in selected hash.
	    #- requested flag is set only for requested package where value is not false.
	    push @selected, $pkg;
	    $state->{selected}{$pkg->id} = { exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
					     exists $dep->{from} ? (from => $dep->{from}) : @{[]},
					     exists $dep->{promote} ? (promote => $dep->{promote}) : @{[]},
					     exists $dep->{psel} ? (psel => $dep->{psel}) : @{[]},
					     $pkg->flag_disable_obsolete ? (install => 1) : @{[]},
					   };

	    $pkg->set_flag_required;

	    #- check if the package is not already installed before trying to use it, compute
	    #- obsoleted packages too. This is valable only for non source packages.
	    if ($pkg->arch ne 'src' && !$pkg->flag_disable_obsolete) {

		push @diff_provides, map { +{ name => $_, pkg => $pkg } } 
		  _compute_diff_provides($urpm, $db, $state, $pkg);
	    }

	    #- all requires should be satisfied according to selected package, or installed packages.
	    if (my @l = unsatisfied_requires($urpm, $db, $state, $pkg)) {
		$urpm->{debug_URPM}("requiring " . join(',', sort @l) . " for " . $pkg->fullname) if $urpm->{debug_URPM};
		unshift @properties, map { +{ required => $_, from => $pkg,
					  exists $dep->{promote} ? (promote => $dep->{promote}) : @{[]},
					  exists $dep->{psel} ? (psel => $dep->{psel}) : @{[]},
					} } @l;
	    }

	    #- keep in mind what is requiring each item (for unselect to work).
	    foreach ($pkg->requires_nosense) {
		$state->{whatrequires}{$_}{$pkg->id} = undef;
	    }

	    #- cancel flag if this package should be cancelled but too late (typically keep options).
	    my @keep;

	    _handle_conflicts($urpm, $db, $state, $pkg, \@properties, $options{keep} && \@keep);

	    #- examine if an existing package does not conflict with this one.
	    $db->traverse_tag('whatconflicts', [ $pkg->name ], sub {
		@keep and return;
		my ($p) = @_;
		foreach my $property ($p->conflicts) {
		    if ($pkg->provides_overlap($property)) {
			_handle_provides_overlap($urpm, $db, $state, $pkg, $p, $property, $pkg->name, \@properties, $options{keep} && \@keep);
		    }
		}
	    });

	    #- keep existing package and therefore cancel current one.
	    if (@keep) {
		backtrack_selected_psel_keep($urpm, $db, $state, $pkg, \@keep);
	    }
	}
	if (my $diff = shift @diff_provides) {
	    _handle_diff_provides($urpm, $db, $state, \@properties, $diff->{name}, $diff->{pkg}, %options);
	}
    } while @diff_provides || @properties;

    #- return what has been selected by this call (not all selected hash which may be not empty
    #- previously. avoid returning rejected packages which weren't selectable.
    grep { exists $state->{selected}{$_->id} } @selected;
}

#- side-effects:
#-   + those of _set_rejected_from ($state->{rejected})
#-   + those of resolve_rejected_ ($properties)
#-   + those of _handle_provides_overlap ($properties, $keep)
sub _handle_conflicts {
    my ($urpm, $db, $state, $pkg, $properties, $keep) = @_;

    #- examine conflicts, an existing package conflicting with this selection should
    #- be upgraded to a new version which will be safe, else it should be removed.
    foreach ($pkg->conflicts) {
	$keep && @$keep and last;
	#- propagate conflicts to avoid
	if (my ($n, $o, $v) = property2name_op_version($_)) {
	    foreach my $p ($urpm->packages_providing($n)) {
		$pkg == $p and next;
		$p->name eq $n && (!$o || eval($p->compare($v) . $o . 0)) or next;
		_set_rejected_from($state, $p, $pkg);
	    }
	}
	if (my ($file) = m!^(/[^\s\[]*)!) {
	    $db->traverse_tag('path', [ $file ], sub {
		$keep && @$keep and return;
		my ($p) = @_;
		if ($keep) {
		    push @$keep, scalar $p->fullname;
		} else {
		    #- all these package should be removed.
		    resolve_rejected_($urpm, $db, $state, $p, $properties,
				      removed => 1,
				      from => $pkg,
				      why => { conflicts => $file },
				  );
		}
	    });
	} elsif (my $name = property2name($_)) {
	    my $property = $_;
	    $db->traverse_tag('whatprovides', [ $name ], sub {
		$keep && @$keep and return;
		my ($p) = @_;
		if ($p->provides_overlap($property)) {
		    _handle_provides_overlap($urpm, $db, $state, $pkg, $p, $property, $name, $properties, $keep);
		}
	    });
	}
    }
}

#- side-effects:
#-   + those of _compute_diff_provides (flag_requested, flag_required, $state->{selected}, $state->{rejected}, $state->{whatrequires}, $state->{oldpackage}, $state->{unselected_uninstalled})
sub _compute_diff_provides {
    my ($urpm, $db, $state, $pkg) = @_;

    my %diff_provides;

    _compute_diff_provides_one($urpm, $db, $state, $pkg, \%diff_provides, $pkg->name, '<', $pkg->epoch . ":" . $pkg->version . "-" . $pkg->release);

    foreach ($pkg->obsoletes) {
	my ($n, $o, $v) = property2name_op_version($_) or next;

	#- ignore if this package obsoletes itself
	#- otherwise this can cause havoc if: to_install=v3, installed=v2, v3 obsoletes < v2
	if ($n ne $pkg->name) {
	    _compute_diff_provides_one($urpm, $db, $state, $pkg, \%diff_provides, $n, $o, $v);
	}
    }
    keys %diff_provides;
}

#- side-effects: $state->{rejected}, $state->{oldpackage}, $state->{unselected_uninstalled}
#-   + those of _set_rejected_from ($state->{rejected})
#-   + those of disable_selected (flag_requested, flag_required, $state->{selected}, $state->{rejected}, $state->{whatrequires})
sub _compute_diff_provides_one {
    my ($urpm, $db, $state, $pkg, $diff_provides, $n, $o, $v) = @_;

    #- populate avoided entries according to what is selected.
    foreach my $p ($urpm->packages_providing($n)) {
	if ($p->name eq $pkg->name) {
	    #- all packages with the same name should now be avoided except when chosen.
	} else {
	    #- in case of obsoletes, keep track of what should be avoided
	    #- but only if package name equals the obsolete name.
	    $p->name eq $n && (!$o || eval($p->compare($v) . $o . 0)) or next;
	}
	#- these packages are not yet selected, if they happen to be selected,
	#- they must first be unselected.
	_set_rejected_from($state, $p, $pkg);
    }
	
    #- examine rpm db too (but only according to package names as a fix in rpm itself)
    $db->traverse_tag('name', [ $n ], sub {
	my ($p) = @_;

	#- without an operator, anything (with the same name) is matched.
	#- with an operator, check package EVR with the obsoletes EVR.
	#- $satisfied is true if installed package has version newer or equal.
	my $comparison = $p->compare($v);
	my $satisfied = !$o || eval($comparison . $o . 0);
	$p->name eq $pkg->name || $satisfied or return;
	
	#- do not propagate now the broken dependencies as they are
	#- computed later.
	my $rv = $state->{rejected}{$p->fullname} ||= {};
	$rv->{closure}{$pkg->fullname} = undef;
	$rv->{size} = $p->size;

	if ($p->name eq $pkg->name) {
	    #- all packages older than the current one are obsoleted,
	    #- the others are simply removed (the result is the same).
	    if ($o && $comparison > 0) {
		#- installed package is newer
		#- remove this package from the list of packages to install,
		#- unless urpmi was invoked with --allow-force (in which
		#- case rpm could be invoked with --oldpackage)
		if (!$urpm->{options}{'allow-force'}) {
		    #- since the originally requested packages (or other
		    #- non-installed ones) could be unselected by the following
		    #- operation, remember them, to warn the user
		    $state->{unselected_uninstalled} = [ grep {
			!$_->flag_installed;
		    } disable_selected($urpm, $db, $state, $pkg) ];
		}
	    } elsif ($satisfied) {
		$rv->{obsoleted} = 1;
	    } else {
		$rv->{closure}{$pkg->fullname} = { old_requested => 1 };
		$rv->{removed} = 1;
		++$state->{oldpackage};
	    }
	} else {
	    $rv->{obsoleted} = 1;
	}

	#- diff_provides on obsoleted provides are needed.
	foreach ($p->provides) {
	    #- check differential provides between obsoleted package and newer one.
	    my ($pn, $ps) = property2name_range($_) or next;

	    $diff_provides->{$pn} = undef;
	    foreach (grep { exists $state->{selected}{$_} }
		       keys %{$urpm->{provides}{$pn} || {}}) {
		my $pp = $urpm->{depslist}[$_];
		foreach ($pp->provides) {
		    my ($ppn, $pps) = property2name_range($_) or next;
		    $ppn eq $pn && $pps eq $ps
		      and delete $diff_provides->{$pn};
		}
	    }
	}
    });
}

#- side-effects: $properties
#-   + those of backtrack_selected_psel_keep ($state->{rejected}, $state->{selected}, $state->{whatrequires}, flag_requested, flag_required)
#-   + those of resolve_rejected_ ($state->{rejected}, $properties)
sub _handle_diff_provides {
    my ($urpm, $db, $state, $properties, $n, $pkg, %options) = @_;

    with_db_unsatisfied_requires($urpm, $db, $state, $n, sub {
	my ($p, @l) = @_;

	#- try if upgrading the package will be satisfying all the requires...
	#- there is no need to avoid promoting epoch as the package examined is not
	#- already installed.
	my @packages = find_candidate_packages_($urpm, $p->name, $state->{rejected});
	my $best = join '|', map { $_->id }
	  grep { ($_->name eq $p->name ||
		    $_->obsoletes_overlap($p->name . " == " . $p->epoch . ":" . $p->version . "-" . $p->release))
		   && $_->fullname ne $p->fullname &&
		     unsatisfied_requires($urpm, $db, $state, $_, name => $n) == 0 }
	    @packages;

	if (length $best) {
	    $urpm->{debug_URPM}("promoting " . $urpm->{depslist}[$best]->fullname . " because of conflict above") if $urpm->{debug_URPM};
	    push @$properties, { required => $best, promote => $n, psel => $pkg };
	} else {
	    #- no package have been found, we may need to remove the package examined unless
	    #- there exists enough packages that provided the unsatisfied requires.
	    my @best;
	    foreach (@l) {
		my @packages = find_candidate_packages_($urpm, $_, $state->{rejected});
		$best = join('|', map { $_->id }
			          grep { $_->fullname ne $p->fullname }
				  @packages);
		$best and push @best, $best;
	    }

	    if (@best == @l) {
		$urpm->{debug_URPM}("promoting " . join(' ', _ids_to_fullnames($urpm, @best)) . " because of conflict above") if $urpm->{debug_URPM};
		push @$properties, map { +{ required => $_, promote => $n, psel => $pkg } } @best;
	    } else {
		if ($options{keep}) {
		    backtrack_selected_psel_keep($urpm, $db, $state, $pkg, [ scalar $p->fullname ]);
		} else {
		    resolve_rejected_($urpm, $db, $state, $p, $properties,
				      removed => 1,
				      from => $pkg,
				      why => { unsatisfied => \@l });
		}
	    }
	}
    });
}

#- side-effects: $properties, $keep, $state->{rejected}
#-   + those of resolve_rejected_ ()
sub _handle_provides_overlap {
    my ($urpm, $db, $state, $pkg, $p, $property, $name, $properties, $keep) = @_;
    
    $urpm->{debug_URPM}("installed package " . $p->fullname . " is conflicting with " . $pkg->fullname . " (Conflicts: $property)") if $urpm->{debug_URPM};

    #- the existing package will conflict with the selection; check
    #- whether a newer version will be ok, else ask to remove the old.
    my $need_deps = $p->name . " > " . ($p->epoch ? $p->epoch . ":" : "") .
      $p->version . "-" . $p->release;
    my $packages = find_candidate_packages($urpm, $need_deps, $state->{rejected});
    my $best = join('|', map { $_->id }
		      grep { ! $_->provides_overlap($property) }
			@{$packages->{$p->name}});

    if (length $best) {
	$urpm->{debug_URPM}("promoting " . $urpm->{depslist}[$best]->fullname . " because of conflict above") if $urpm->{debug_URPM};
	unshift @$properties, { required => $best, promote_conflicts => $name };
    } else {
	if ($keep) {
	    push @$keep, scalar $p->fullname;
	} else {
	    #- no package has been found, we need to remove the package examined.
	    resolve_rejected_($urpm, $db, $state, $p, $properties,
		removed => 1,
		from => $pkg,
		why => { conflicts => $property },
	    );
	}
    }
}

#- side-effects: none
sub _dep_to_name {
    my ($urpm, $dep) = @_;
    _id_to_name($urpm, $dep->{required});
}
#- side-effects: none
sub _id_to_name {
    my ($urpm, $id_prop) = @_;
    if ($id_prop =~ /^\d+/) {
	my $pkg = $urpm->{depslist}[$id_prop];
	$pkg && $pkg->name;
    } else {
	$id_prop;
    }
}
#- side-effects: none
sub _ids_to_names {
    my $urpm = shift;

    map { $urpm->{depslist}[$_]->name } @_;
}
#- side-effects: none
sub _ids_to_fullnames {
    my $urpm = shift;

    map { scalar $urpm->{depslist}[$_]->fullname } @_;
}

#- side-effects: flag_installed, flag_upgrade
sub _set_flag_installed_and_upgrade_if_no_newer {
    my ($db, $pkg) = @_;

    !$pkg->flag_upgrade && !$pkg->flag_installed or return;

    my $upgrade = 1;
    $db->traverse_tag('name', [ $pkg->name ], sub {
	my ($p) = @_;
	$pkg->set_flag_installed;
	$upgrade &&= $pkg->compare_pkg($p) > 0;
    });
    $pkg->set_flag_upgrade($upgrade);
}

#- side-effects: none
sub _no_more_recent_installed_and_providing {
    my ($urpm, $db, $pkg, $required) = @_;

    my $allow = 1;
    $db->traverse_tag('name', [ $pkg->name ], sub {
	my ($p) = @_;
	#- allow if a less recent package is installed,
	if ($allow && $pkg->compare_pkg($p) <= 0) {
	    if ($required =~ /^\d+/ || $p->provides_overlap($required)) {
		$urpm->{debug_URPM}("not selecting " . $pkg->fullname . " since the more recent " . $p->fullname . " is installed") if $urpm->{debug_URPM};
		$allow = 0;
	    } else {
		$urpm->{debug_URPM}("the more recent " . $p->fullname . 
		  " is installed, but does not provide $required whereas " . 
		    $pkg->fullname . " does") if $urpm->{debug_URPM};
	    }
	}
    });
    $allow;
}

#- do the opposite of the resolve_requested:
#-   unselect a package and extend to any package not requested that is no
#-   longer needed by any other package.
#- return the packages that have been deselected.
#-
#- side-effects: flag_requested, flag_required, $state->{selected}, $state->{whatrequires}
#-   + those of _remove_all_rejected_from ($state->{rejected})
sub disable_selected {
    my ($urpm, $db, $state, @pkgs_todo) = @_;
    my @unselected;

    #- iterate over package needing unrequested one.
    while (my $pkg = shift @pkgs_todo) {
	exists $state->{selected}{$pkg->id} or next;

	#- keep a trace of what is deselected.
	push @unselected, $pkg;

	#- perform a closure on rejected packages (removed, obsoleted or avoided).
	my @rejected_todo = scalar $pkg->fullname;
	while (my $fullname = shift @rejected_todo) {
	    push @rejected_todo, _remove_all_rejected_from($state, $fullname);
	}

	#- the package being examined has to be unselected.
	$pkg->set_flag_requested(0);
	$pkg->set_flag_required(0);
	delete $state->{selected}{$pkg->id};

	#- determine package that requires properties no longer available, so that they need to be
	#- unselected too.
	foreach my $n ($pkg->provides_nosense) {
	    foreach my $p (whatrequires($urpm, $state, $n)) {
		exists $state->{selected}{$p->id} or next;
		if (unsatisfied_requires($urpm, $db, $state, $p, name => $n)) {
		    #- this package has broken dependencies and is selected.
		    push @pkgs_todo, $p;
		}
	    }
	}

	#- clean whatrequires hash.
	foreach ($pkg->requires_nosense) {
	    delete $state->{whatrequires}{$_}{$pkg->id};
	    %{$state->{whatrequires}{$_}} or delete $state->{whatrequires}{$_};
	}
    }

    #- return all unselected packages.
    @unselected;
}

#- determine dependencies that can safely been removed and are not requested
#- return the packages that have been deselected.
#-
#- side-effects:
#-   + those of disable_selected (flag_requested, flag_required, $state->{selected}, $state->{whatrequires}, $state->{rejected})
sub disable_selected_and_unrequested_dependencies {
    my ($urpm, $db, $state, @pkgs_todo) = @_;
    my @all_unselected;

    #- disable selected packages, then extend unselection to all required packages
    #- no longer needed and not requested.
    while (my @unselected = disable_selected($urpm, $db, $state, @pkgs_todo)) {
	my %required;

	#- keep in the packages that had to be unselected.
	@all_unselected or push @all_unselected, @unselected;

	#- search for unrequested required packages.
	foreach (@unselected) {
	    foreach ($_->requires_nosense) {
		foreach my $pkg (grep { $_ } $urpm->packages_providing($_)) {
		    $state->{selected}{$pkg->id} or next;
		    $state->{selected}{$pkg->id}{psel} && $state->{selected}{$state->{selected}{$pkg->id}{psel}->id} and next;
		    $pkg->flag_requested and next;
		    $required{$pkg->id} = undef;
		}
	    }
	}

	#- check required packages are not needed by another selected package.
	foreach (keys %required) {
	    my $pkg = $urpm->{depslist}[$_] or next;
	    foreach ($pkg->provides_nosense) {
		foreach my $p_id (whatrequires_id($state, $_)) {
		    exists $required{$p_id} and next;
		    $state->{selected}{$p_id} and $required{$pkg->id} = 1;
		}
	    }
	}

	#- now required values still undefined indicates packages than can be removed.
	@pkgs_todo = map { $urpm->{depslist}[$_] } grep { !$required{$_} } keys %required;
    }

    @all_unselected;
}

#- compute selected size by removing any removed or obsoleted package.
#-
#- side-effects: none
sub selected_size {
    my ($urpm, $state) = @_;
    my $size;

    foreach (keys %{$state->{selected} || {}}) {
	my $pkg = $urpm->{depslist}[$_];
	$size += $pkg->size;
    }

    foreach (values %{$state->{rejected} || {}}) {
	$_->{removed} || $_->{obsoleted} or next;
	$size -= $_->{size};
    }

    $size;
}

#- compute installed flags for all packages in depslist.
#-
#- side-effects: flag_upgrade, flag_installed
sub compute_installed_flags {
    my ($urpm, $db) = @_;

    #- first pass to initialize flags installed and upgrade for all packages.
    foreach (@{$urpm->{depslist}}) {
	$_->is_arch_compat or next;
	$_->flag_upgrade || $_->flag_installed or $_->set_flag_upgrade;
    }

    #- second pass to set installed flag and clean upgrade flag according to installed packages.
    $db->traverse(sub {
	my ($p) = @_;
	#- compute flags.
	foreach my $pkg ($urpm->packages_providing($p->name)) {
	    next if !defined $pkg;
	    $pkg->is_arch_compat && $pkg->name eq $p->name or next;
	    #- compute only installed and upgrade flags.
	    $pkg->set_flag_installed; #- there is at least one package installed (whatever its version).
	    $pkg->flag_upgrade and $pkg->set_flag_upgrade($pkg->compare_pkg($p) > 0);
	}
    });
}

#- side-effects: flag_skip, flag_disable_obsolete
sub compute_flag {
    my ($urpm, $pkg, %options) = @_;
    foreach (qw(skip disable_obsolete)) {
	if ($options{$_} && !$pkg->flag($_)) {
	    $pkg->set_flag($_, 1);
	    $options{callback} and $options{callback}->($urpm, $pkg, %options);
	}
    }
}

#- Adds packages flags according to an array containing packages names.
#- $val is an array reference (as returned by get_packages_list) containing
#- package names, or a regular expression matching against the fullname, if
#- enclosed in slashes.
#- %options :
#-   callback : sub to be called for each package where the flag is set
#-   skip : if true, set the 'skip' flag
#-   disable_obsolete : if true, set the 'disable_obsolete' flag
#-
#- side-effects: 
#-   + those of compute_flag (flag_skip, flag_disable_obsolete)
sub compute_flags {
    my ($urpm, $val, %options) = @_;
    if (ref $val eq 'HASH') { $val = [ keys %$val ] } #- compatibility with urpmi <= 4.5-13mdk
    my @regex;

    #- unless a regular expression is given, search in provides
    foreach my $name (@$val) {
	if ($name =~ m,^/(.*)/$,) {
	    push @regex, $1;
	} else {
	    foreach my $pkg ($urpm->packages_providing($name)) {
		compute_flag($urpm, $pkg, %options);
	    }
	}
    }

    #- now search packages which fullname match given regexps
    if (@regex) {
	#- very costly :-(
	foreach my $pkg (@{$urpm->{depslist}}) {
	    if (grep { $pkg->fullname =~ /$_/ } @regex) {
		compute_flag($urpm, $pkg, %options);
	    }
	}
    }
}

#- select packages to upgrade, according to package already registered.
#- by default, only takes best package and its obsoleted and compute
#- all installed or upgrade flag.
#- (used for --auto-select)
#-
#- side-effects: 
#-   + those of _request_packages_to_upgrade_2 (flag_install, flag_upgrade)
sub request_packages_to_upgrade {
    my ($urpm, $db, $_state, $requested, %options) = @_;

    my ($names, $obsoletes) = _request_packages_to_upgrade_1($urpm, %options) or return;
    _request_packages_to_upgrade_2($urpm, $db, $requested, $names, $obsoletes, %options);
}

#- side-effects: none
sub _request_packages_to_upgrade_1 {
    my ($urpm, %options) = @_;
    my (%names, %skip);

    my @idlist = $urpm->build_listid($options{start}, $options{end}, $options{idlist}) or return;
    
    #- build direct access to best package per name.
    foreach my $pkg (@{$urpm->{depslist}}[@idlist]) {

	if ($pkg->is_arch_compat) {
	    my $p = $names{$pkg->name};
	    !$p || $pkg->compare_pkg($p) > 0 and $names{$pkg->name} = $pkg;
	}
    }

    #- cleans up direct access, a package in %names should have
    #- checked consistency with obsoletes of eligible packages.
    #- It is important to avoid selecting a package that obsoletes
    #- an old one.
    my %obsoletes;
    foreach my $pkg (values %names) {
	foreach ($pkg->obsoletes) {
	    if (my ($n, $o, $v) = property2name_op_version($_)) {
		if ($n ne $pkg->name && $names{$n} && (!$o || eval($names{$n}->compare($v) . $o . 0))) {
		    #- an existing best package is obsoleted by another one.
		    $skip{$n} = undef;
		}
		push @{$obsoletes{$n}}, $pkg;
	    }
	}
    }

    #- ignore skipped packages.
    delete @names{keys %skip};

    \%names, \%obsoletes;
}

#- side-effects: flag_installed, flag_upgrade
sub _request_packages_to_upgrade_2 {
    my ($_urpm, $db, $requested, $names, $obsoletes, %options) = @_;
    my %names = %$names;
    my (%requested, @obsoleters);

    #- now we can examine all existing packages to find packages to upgrade.
    $db->traverse(sub {
	my ($p) = @_;
	my $pn = $p->name;
	#- first try with package using the same name.
	#- this will avoid selecting all packages obsoleting an old one.
	if (my $pkg = $names{$pn}) {
	    my $may_upgrade = $pkg->flag_upgrade || #- it is has already been flagged upgradable
	         !$pkg->flag_installed && do {
		     $pkg->set_flag_installed; #- there is at least one package installed (whatever its version).
		     1;
		 };
	    if ($may_upgrade && $pkg->compare_pkg($p) > 0) {
		#- keep in mind the package is requested.
		$pkg->set_flag_upgrade;
		$requested{$pn} = undef;
	    } else {
		delete $names{$pn};
	    }
	}

	#- check provides of existing package to see if an obsolete
	#- may allow selecting it.
	foreach my $property ($p->provides) {
	    #- only real provides should be taken into account, this means internal obsoletes
	    #- should be avoided.
	    unless ($p->obsoletes_overlap($property)) {
		if (my $n = property2name($property)) {
		    foreach my $pkg (@{$obsoletes->{$n} || []}) {
			next if $pkg->name eq $pn || $pn ne $n || !$names{$pkg->name};
			if ($pkg->obsoletes_overlap($property)) {
			    #- the package being examined can be obsoleted.
			    #- do not set installed and provides flags.
			    push @obsoleters, $pkg;
			    return;
			}
		    }
		}
	    }
	}
    });

    #- examine all obsoleter packages, compute installer and upgrade flag if needed.
    foreach my $pkg (@obsoleters) {
	next if !$names{$pkg->name};

	_set_flag_installed_and_upgrade_if_no_newer($db, $pkg);

	if ($pkg->flag_installed && !$pkg->flag_upgrade) {
	    delete $names{$pkg->name};
	} else {
	    $requested{$pkg->name} = undef;
	}
    }

    #- examine all packages which may be conflicting. If a package conflicts, it should not be requested.
    my @names = map { $_->name . " == " . $_->epoch . ":" . $_->version . "-" . $_->release } values %names;
    my @pkgs = values %names;
    foreach my $pkg (@pkgs) {
	exists $requested{$pkg->name} or next;
	foreach my $conflict ($pkg->conflicts) {
	    delete @names{map { /(\S*)/ && $1 } grep { ranges_overlap($conflict, $_) } @names};
	}
    }

    #- examine all packages potentially selectable.
    foreach my $pkg (values %names) {
	exists $requested{$pkg->name} and $requested->{$pkg->id} = $options{requested};
    }

    $requested;
}

#- side-effects: none
sub _sort_by_dependencies_get_graph {
    my ($urpm, $state, $l) = @_;
    my %edges;
    foreach my $id (@$l) {
	my $pkg = $urpm->{depslist}[$id];
	my @provides = map { whatrequires_id($state, $_) } $pkg->provides_nosense;
	if (my $from = $state->{selected}{$id}{from}) {
	    unshift @provides, $from->id;
	}
	$edges{$id} = [ uniq(@provides) ];
    }
    \%edges;
}

#- side-effects: none
sub reverse_multi_hash {
    my ($h) = @_;
    my %r;
    my ($k, $v);
    while (($k, $v) = each %$h) {
	push @{$r{$_}}, $k foreach @$v;
    }
    \%r;
}

#- nb: this handles $nodes list not containing all $nodes that can be seen in $edges
#-
#- side-effects: none
sub sort_graph {
    my ($nodes, $edges) = @_;

    #require Data::Dumper;
    #warn Data::Dumper::Dumper($nodes, $edges);

    my %nodes_h = map { $_ => 1 } @$nodes;
    my (%loops, %added, @sorted);

    my $merge_loops = sub {
	my ($l1, $l2) = @_;
	my $l = [ @$l1, @$l2 ];
	$loops{$_} = $l foreach @$l;
	$l;
    };
    my $add_loop = sub {
	my (@ids) = @_;
	my ($main, @other) = uniq(grep { $_ } map { $loops{$_} } @ids);
	$main ||= [];
	if (@other) {
	    $main = $merge_loops->($main, $_) foreach @other;
	}
	foreach (grep { !$loops{$_} } @ids) {
	    $loops{$_} ||= $main;
	    push @$main, $_;
	    my @l_ = uniq(@$main);
	    @l_ == @$main or die '';
	}
#	warn "# loops: ", join(' ', map { join('+', @$_) } uniq(values %loops)), "\n";
    };

    my $recurse; $recurse = sub {
	my ($id, @ids) = @_;
#	warn "# recurse $id @ids\n";

	my $loop_ahead;
	foreach my $p_id (@{$edges->{$id}}) {
	    if ($p_id == $id) {
		# don't care
	    } elsif (exists $added{$p_id}) {
		# already done
	    } elsif (grep { $_ == $p_id } @ids) {
		my $begin = 1;
		my @l = grep { $begin &&= $_ != $p_id } @ids;
		$loop_ahead = 1;
		$add_loop->($p_id, $id, @l);
	    } elsif ($loops{$p_id}) {
		my $take;
		if (my @l = grep { $take ||= $loops{$_} && $loops{$_} == $loops{$p_id} } reverse @ids) {
		    $loop_ahead = 1;
#		    warn "# loop to existing one $p_id, $id, @l\n";
		    $add_loop->($p_id, $id, @l);
		}
	    } else {
		$recurse->($p_id, $id, @ids);
		#- we would need to compute loop_ahead. we will do it below only once, and if not already set
	    }
	}
	if (!$loop_ahead && $loops{$id} && grep { exists $loops{$_} && $loops{$_} == $loops{$id} } @ids) {
	    $loop_ahead = 1;
	}

	if (!$loop_ahead) {
	    #- it's now a leaf or a loop we're done with
	    my @toadd = $loops{$id} ? @{$loops{$id}} : $id;
	    $added{$_} = undef foreach @toadd;
#	    warn "# adding ", join('+', @toadd), " for $id\n";
	    push @sorted, [ uniq(grep { $nodes_h{$_} } @toadd) ];
	}
    };
    !exists $added{$_} and $recurse->($_) foreach @$nodes;

#    warn "# result: ", join(' ', map { join('+', @$_) } @sorted), "\n";

    check_graph_is_sorted(\@sorted, $nodes, $edges) or die "sort_graph failed";
    
    @sorted;
}

#- side-effects: none
sub check_graph_is_sorted {
    my ($sorted, $nodes, $edges) = @_;

    my $i = 1;
    my %nb;
    foreach (@$sorted) {
	$nb{$_} = $i foreach @$_;
	$i++;
    }
    my $nb_errors = 0;
    my $error = sub { $nb_errors++; warn "error: $_[0]\n" };

    foreach my $id (@$nodes) {
	$nb{$id} or $error->("missing $id in sort_graph list");
    }
    foreach my $id (keys %$edges) {
	my $id_i = $nb{$id} or next;
	foreach my $req (@{$edges->{$id}}) {
	    my $req_i = $nb{$req} or next;
	    $req_i <= $id_i or $error->("$req should be before $id ($req_i $id_i)");
	}
    }
    $nb_errors == 0;
}


#- side-effects: none
sub _sort_by_dependencies__add_obsolete_edges {
    my ($urpm, $state, $l, $requires) = @_;

    my @obsoletes = grep { $_->{obsoleted} } values %{$state->{rejected}} or return;

    my %fullnames = map { scalar($urpm->{depslist}[$_]->fullname) => $_ } @$l;
    foreach my $rej (@obsoletes) {
	my @group = map { $fullnames{$_} } keys %{$rej->{closure}};
	@group > 1 or next;
	foreach (@group) {
	    @{$requires->{$_}} = uniq(@{$requires->{$_}}, @group);
	}
    }
}

#- side-effects: none
sub sort_by_dependencies {
    my ($urpm, $state, @list_unsorted) = @_;
    @list_unsorted = sort { $a <=> $b } @list_unsorted; # sort by ids to be more reproductable
    $urpm->{debug_URPM}("getting graph of dependencies for sorting") if $urpm->{debug_URPM};
    my $edges = _sort_by_dependencies_get_graph($urpm, $state, \@list_unsorted);
    my $requires = reverse_multi_hash($edges);

    _sort_by_dependencies__add_obsolete_edges($urpm, $state, \@list_unsorted, $requires);

    $urpm->{debug_URPM}("sorting graph of dependencies") if $urpm->{debug_URPM};
    sort_graph(\@list_unsorted, $requires);
}

sub sorted_rpms_to_string {
    my ($urpm, @sorted) = @_;

    'rpms sorted by dependance: ' . join(' ', map { 
	join('+', _ids_to_names($urpm, @$_));
    } @sorted);
}

#- build transaction set for given selection
#-
#- side-effects: $state->{transaction}, $state->{transaction_state}
sub build_transaction_set {
    my ($urpm, $db, $state, %options) = @_;

    #- clean transaction set.
    $state->{transaction} = [];

    my %selected_id;
    @selected_id{$urpm->build_listid($options{start}, $options{end}, $options{idlist})} = ();
    
    if ($options{split_length}) {
	#- first step consists of sorting packages according to dependencies.
	my @sorted = sort_by_dependencies($urpm, $state,
	   keys(%selected_id) > 0 ? 
	      (grep { exists($selected_id{$_}) } keys %{$state->{selected}}) : 
	      keys %{$state->{selected}});
	$urpm->{debug_URPM}(sorted_rpms_to_string($urpm, @sorted)) if $urpm->{debug_URPM};

	#- second step consists of re-applying resolve_requested in the same
	#- order computed in first step and to update a list of packages to
	#- install, to upgrade and to remove.
	my %examined;
	my @todo = @sorted;
	while (@todo) {
	    my @ids;
	    while (@todo && @ids < $options{split_length}) {
		my $l = shift @todo;
		push @ids, @$l;
	    }
	    my %requested = map { $_ => undef } @ids;

		resolve_requested__no_suggests_($urpm,
		    $db, $state->{transaction_state} ||= {},
		    \%requested,
		    defined $options{start} ? (start => $options{start}) : @{[]},
		    defined $options{end}   ? (end   => $options{end}) : @{[]},
		);

		my @upgrade = grep { ! exists $examined{$_} } keys %{$state->{transaction_state}{selected}};
		my @remove = grep { $state->{transaction_state}{rejected}{$_}{removed} &&
				    !$state->{transaction_state}{rejected}{$_}{obsoleted} }
		             grep { ! exists $examined{$_} } keys %{$state->{transaction_state}{rejected}};

		@upgrade || @remove or next;

		if (my @bad_remove = grep { !$state->{rejected}{$_}{removed} || $state->{rejected}{$_}{obsoleted} } @remove) {
		    $urpm->{error}(sorted_rpms_to_string($urpm, @sorted)) if $urpm->{error};
		    $urpm->{error}('transaction is too small: ' . join(' ', @bad_remove) . ' is rejected but it should not (current transaction: ' . join(' ', _ids_to_fullnames($urpm, @upgrade)) . ', requested: ' . join('+', _ids_to_fullnames($urpm, @ids)) . ')') if $urpm->{error};
		    $state->{transaction} = [];
		    last;
		}

		$urpm->{debug_URPM}(sprintf('transaction valid: remove=%s update=%s',
					    join(',', @remove),
					    join(',', _ids_to_names($urpm, @upgrade)))) if $urpm->{debug_URPM};
    
		$examined{$_} = undef foreach @upgrade, @remove;
		push @{$state->{transaction}}, { upgrade => \@upgrade, remove => \@remove };
	}

	#- check that the transaction set has been correctly created.
	#- (ie that no other package was removed)
	if (keys(%{$state->{selected}}) == keys(%{$state->{transaction_state}{selected}}) &&
	    (grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}}) ==
	    (grep { $state->{transaction_state}{rejected}{$_}{removed} && !$state->{transaction_state}{rejected}{$_}{obsoleted} }
	     keys %{$state->{transaction_state}{rejected}})
	   ) {
	    foreach (keys(%{$state->{selected}})) {
		exists $state->{transaction_state}{selected}{$_} and next;
		$urpm->{error}('using one big transaction') if $urpm->{error};
		$state->{transaction} = []; last;
	    }
	    foreach (grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}}) {
		$state->{transaction_state}{rejected}{$_}{removed} &&
		  !$state->{transaction_state}{rejected}{$_}{obsoleted} and next;
		$urpm->{error}('using one big transaction') if $urpm->{error};
		$state->{transaction} = []; last;
	    }
	}
    }

    #- fallback if something can be selected but nothing has been allowed in transaction list.
    if (%{$state->{selected} || {}} && !@{$state->{transaction}}) {
	$urpm->{debug_URPM}('using one big transaction') if $urpm->{debug_URPM};
	push @{$state->{transaction}}, {
					upgrade => [ keys %{$state->{selected}} ],
					remove  => [ grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} }
						     keys %{$state->{rejected}} ],
				       };
    }

    $state->{transaction};
}

1;
