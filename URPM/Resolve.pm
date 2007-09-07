package URPM;

# $Id$

use strict;
use Config;

sub min { my $n = shift; $_ < $n and $n = $_ foreach @_; $n }
sub uniq { my %l; $l{$_} = 1 foreach @_; grep { delete $l{$_} } @_ }

#- $state fields :
#- * ask_remove: deprecated
#- * backtrack
#- * cached_installed
#- * oldpackage
#- * rejected
#- * selected
#- * transaction
#- * transaction_state
#- * unselected: deprecated
#- * whatrequires

#- Find candidates packages from a require string (or id).
#- Takes care of direct choices using the '|' separator.
sub find_candidate_packages {
    my ($urpm, $dep, %options) = @_;
    my %packages;
    $options{nopromoteepoch} = 1 unless defined $options{nopromoteepoch};

    foreach (split /\|/, $dep) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->flag_skip and next;
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    $options{avoided} && exists $options{avoided}{$pkg->fullname} and next;
	    push @{$packages{$pkg->name}}, $pkg;
	} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->flag_skip and next;
		$pkg->is_arch_compat or next;
		$options{avoided} && exists $options{avoided}{$pkg->fullname} and next;
		#- check if at least one provide of the package overlap the property.
		!$urpm->{provides}{$name}{$_} || $pkg->provides_overlap($property, $options{nopromoteepoch})
		    and push @{$packages{$pkg->name}}, $pkg;
	    }
	}
    }
    \%packages;
}

sub get_installed_arch {
    my ($db, $n) = @_;
    my $arch;
    $db->traverse_tag('name', [ $n ], sub { $arch = $_[0]->arch });
    $arch;
}

sub find_chosen_packages {
    my ($urpm, $db, $state, $dep) = @_;
    my %packages;
    my %installed_arch;
    my $strict_arch = defined $urpm->{options}{'strict-arch'} ? $urpm->{options}{'strict-arch'} : $Config{archname} =~ /x86_64|sparc64|ppc64/;

    #- search for possible packages, try to be as fast as possible, backtrack can be longer.
    foreach (split /\|/, $dep) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    $pkg->flag_skip || $state->{rejected}{$pkg->fullname} and next;
	    #- determine if this package is better than a possibly previously chosen package.
	    $pkg->flag_selected || exists $state->{selected}{$pkg->id} and return $pkg;
	    if ($strict_arch && $pkg->arch ne 'src' && $pkg->arch ne 'noarch') {
		my $n = $pkg->name;
		defined $installed_arch{$n} or $installed_arch{$n} = get_installed_arch($db, $n);
		if ($installed_arch{$n} && $installed_arch{$n} ne 'noarch') {
		    $pkg->arch eq $installed_arch{$n} or next;
		}
	    }
	    if (my $p = $packages{$pkg->name}) {
		$pkg->flag_requested > $p->flag_requested ||
		  $pkg->flag_requested == $p->flag_requested && $pkg->compare_pkg($p) > 0 and $packages{$pkg->name} = $pkg;
	    } else {
		$packages{$pkg->name} = $pkg;
	    }
	} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->is_arch_compat or next;
		$pkg->flag_skip || exists $state->{rejected}{$pkg->fullname} and next;
		#- check if at least one provide of the package overlaps the property
		if (!$urpm->{provides}{$name}{$_} || $pkg->provides_overlap($property)) {
		    #- determine if this package is better than a possibly previously chosen package.
		    $pkg->flag_selected || exists $state->{selected}{$pkg->id} and return $pkg;
		    if ($strict_arch && $pkg->arch ne 'src' && $pkg->arch ne 'noarch') {
			my $n = $pkg->name;
			defined $installed_arch{$n} or $installed_arch{$n} = get_installed_arch($db, $n);
			$installed_arch{$n} && $pkg->arch ne $installed_arch{$n} and next;
		    }
		    if (my $p = $packages{$pkg->name}) {
			$pkg->flag_requested > $p->flag_requested ||
			  $pkg->flag_requested == $p->flag_requested && $pkg->compare_pkg($p) > 0 and $packages{$pkg->name} = $pkg;
		    } else {
			$packages{$pkg->name} = $pkg;
		    }
		}
	    }
	}
    }

    if (keys(%packages) > 1) {
	#- packages should be preferred if one of their provides is referenced
	#- in the "requested" hash, or if the package itself is requested (or
	#- required).
	#- If there is no preference, choose the first one by default (higher
	#- probability of being chosen) and ask the user.
	#- Packages with more compatibles architectures are always preferred.
	#- Puts the results in @chosen. Other are left unordered.
	foreach my $p (values(%packages)) {
	    _set_flag_installed_and_upgrade_if_no_newer($db, $p);
	}

	my ($best, @other) = sort { 
	    $a->[1] <=> $b->[1] #- we want the lowest (ie preferred arch)
	      || $b->[2] <=> $a->[2]; #- and the higher
	} map {
	    my $score = 0;
	    $score += 2 if $_->flag_requested;
	    $score += $_->flag_upgrade ? 1 : -1 if $_->flag_installed;
	    [ $_, $_->is_arch_compat, $score ];
	} values %packages;

	my @chosen_with_score = ($best, grep { $_->[1] == $best->[1] && $_->[2] == $best->[2] } @other);
	my @chosen = map { $_->[0] } @chosen_with_score;

	#- return immediately if there is only one chosen package
	if (@chosen == 1) { return @chosen }

	#- if several packages were selected to match a requested installation,
	#- and if --more-choices wasn't given, trim the choices to the first one.
	if (!$urpm->{options}{morechoices} && $chosen_with_score[0][2] == 3) {
	    return $chosen[0];
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
	    return @k_chosen if $stripped_kernel;
	}

	my (@chosen_good_locales, @chosen_bad_locales, @chosen_other, @chosen_other_en);

	#- Now we split @chosen in priority lists depending on locale.
	#- Packages that require locales-xxx when the corresponding locales are
	#- already installed should be preferred over packages that require locales
	#- which are not installed.
	foreach (@chosen) {
	    my @r = $_->requires_nosense;
	    if (my ($specific_locales) = grep { /locales-(?!en)/ } @r) {
		if ((grep { $urpm->{depslist}[$_]->flag_available } keys %{$urpm->{provides}{$specific_locales}}) > 0 ||
		    $db->traverse_tag('name', [ $specific_locales ], undef) > 0) {
		    push @chosen_good_locales, $_;
		} else {
		    push @chosen_bad_locales, $_;
		}
	    } else {
		if (grep /locales-en/, @r) {
		    push @chosen_other_en, $_;
		} else {
		    push @chosen_other, $_;
		}
	    }
	}

	#- sort packages in order to have preferred ones first
	#- (this means good locales, no locales, bad locales).
	return sort_package_result($urpm, @chosen_good_locales),
	       sort_package_result($urpm, @chosen_other_en),
	       sort_package_result($urpm, @chosen_other),
	       sort_package_result($urpm, @chosen_bad_locales);
    } else {
	return values(%packages);
    }
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

sub sort_package_result { 
    my ($urpm, @l) = @_;
    if ($urpm->{media}) {
	map { $_->[0] } sort {
	    $a->[1] != $b->[1] ? 
	       $a->[0]->id <=> $b->[0]->id : 
	       $b->[0]->compare_pkg($a->[0]);
	} map { [ $_, pkg2media($urpm->{media}, $_) ] } @l;
    } else {
	$urpm->{debug_URPM}("can't sort choices by media") if $urpm->{debug_URPM};
	sort { $b->compare_pkg($a) || $a->id <=> $b->id } @l;
    }
}

#- return unresolved requires of a package (a new one or an existing one).
sub unsatisfied_requires {
    my ($urpm, $db, $state, $pkg, %options) = @_;
    my %properties;
    $options{nopromoteepoch} = 1 unless defined $options{nopromoteepoch};

    #- all requires should be satisfied according to selected packages or installed packages,
    #- or the package itself.
  REQUIRES: foreach my $dep ($pkg->requires) {
	if (my ($n, $s) = $dep =~ /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
	    #- allow filtering on a given name (to speed up some search).
	    ! defined $options{name} || $n eq $options{name} or next REQUIRES;

	    #- avoid recomputing the same all the time.
	    exists $properties{$dep} and next REQUIRES;

	    #- check for installed packages in the installed cache.
	    foreach (keys %{$state->{cached_installed}{$n} || {}}) {
		exists $state->{rejected}{$_} and next;
		next REQUIRES;
	    }

	    #- check on the selected package if a provide is satisfying the resolution (need to do the ops).
	    foreach (keys %{$urpm->{provides}{$n} || {}}) {
		my $p = $urpm->{depslist}[$_];
		exists $state->{selected}{$_} or next;
		!$urpm->{provides}{$n}{$_} || $p->provides_overlap($dep, $options{nopromoteepoch}) and next REQUIRES;
	    }

	    #- check if the package itself provides what is necessary.
	    $pkg->provides_overlap($dep) and next REQUIRES;

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
			if (my ($pn, $ps) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
			    $ps or $state->{cached_installed}{$pn}{$p->fullname} = undef;
			    $pn eq $n or next;
			    ranges_overlap($ps, $s, $options{nopromoteepoch}) and ++$satisfied;
			}
		    }
		});
	    }
	    #- if nothing can be done, the require should be resolved.
	    $satisfied or $properties{$dep} = undef;
	}
    }

    keys %properties;
}

#- this function is "suggests vs requires" safe:
#-   'whatrequires' will give both requires & suggests, but unsatisfied_requires
#-   will check $p->requires and so filter out suggests
sub with_db_unsatisfied_requires {
    my ($urpm, $db, $state, $name, $do) = @_;

    $db->traverse_tag('whatrequires', [ $name ], sub {
	my ($p) = @_;
	if (my @l = $urpm->unsatisfied_requires($db, $state, $p, name => $name)) {
	    $do->($p, @l);
	}
    });
}

sub backtrack_selected {
    my ($urpm, $db, $state, $dep, %options) = @_;
    my @properties;

    if (defined $dep->{required}) {
	#- avoid deadlock here...
	if (exists $state->{backtrack}{deadlock}{$dep->{required}}) {
	    $options{keep} = 1; #- force keeping package to that backtrakc is doing something.
	} else {
	    $state->{backtrack}{deadlock}{$dep->{required}} = undef;

	    #- search for all possible packages, first is to try the selection, then if it is
	    #- impossible, backtrack the origin.
	    my $packages = $urpm->find_candidate_packages($dep->{required});

	    foreach (values %$packages) {
		foreach (@$_) {
		    #- avoid dead loop.
		    exists $state->{backtrack}{selected}{$_->id} and next;
		    #- a package if found is problably rejected or there is a problem.
		    if ($state->{rejected}{$_->fullname}) {
			if (!$options{callback_backtrack} ||
			    $options{callback_backtrack}->($urpm, $db, $state, $_,
							   dep => $dep, alternatives => $packages, %options) <= 0) {
			    #- keep in mind a backtrack has happening here...
			    $state->{rejected}{$_->fullname}{backtrack} ||=
			      { exists $dep->{promote} ? (promote => [ $dep->{promote} ]) : @{[]},
				exists $dep->{psel} ? (psel => $dep->{psel}) : @{[]},
			      };
			    #- backtrack callback should return a strictly positive value if the selection of the new
			    #- package is prefered over the currently selected package.
			    next;
			}
		    }
		    $state->{backtrack}{selected}{$_->id} = undef;

		    #- in such case, we need to drop the problem caused so that rejected condition is removed.
		    #- if this is not possible, the next backtrack on the same package will be refused above.
		    my @l = map { $urpm->search($_, strict_fullname => 1) }
		      keys %{($state->{rejected}{$_->fullname} || {})->{closure}};

		    $options{keep_unrequested_dependencies} ? $urpm->disable_selected($db, $state, @l) :
		      $urpm->disable_selected_unrequested_dependencies($db, $state, @l);

		    return { required => $_->id,
			     exists $dep->{from} ? (from => $dep->{from}) : @{[]},
			     exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
			   };
		}
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
		my @l = $options{keep_unrequested_dependencies} ? $urpm->disable_selected($db, $state, $dep->{from}) :
		  $urpm->disable_selected_unrequested_dependencies($db, $state, $dep->{from});
		foreach (@l) {
		    #- disable all these packages in order to avoid selecting them again.
		    $_->fullname eq $dep->{from}->fullname or
		      $state->{rejected}{$_->fullname}{backtrack}{closure}{$dep->{from}->fullname} = undef;
		}
	    }
	    #- the package is already rejected, we assume we can add another reason here!
	    $urpm->{debug_URPM}("adding a reason to already rejected package " . $dep->{from}->fullname . ": unsatisfied " . $dep->{required}) if $urpm->{debug_URPM};
	    
	    push @{$state->{rejected}{$dep->{from}->fullname}{backtrack}{unsatisfied}}, $dep->{required};
	}
    }

    if (defined $dep->{psel}) {
	if ($options{keep}) {
	    #- we shouldn't try to remove packages, so psel which leads to this need to be unselected.
	    unless (exists $state->{rejected}{$dep->{psel}->fullname}) {
		#- package is not currently rejected, compute the closure now.
		my @l = $options{keep_unrequested_dependencies} ? $urpm->disable_selected($db, $state, $dep->{psel}) :
		  $urpm->disable_selected_unrequested_dependencies($db, $state, $dep->{psel});
		foreach (@l) {
		    #- disable all these packages in order to avoid selecting them again.
		    $_->fullname eq $dep->{psel}->fullname or
		      $state->{rejected}{$_->fullname}{backtrack}{closure}{$dep->{psel}->fullname} = undef;
		}
	    }
	    #- the package is already rejected, we assume we can add another reason here!
	    defined $dep->{promote} and push @{$state->{rejected}{$dep->{psel}->fullname}{backtrack}{promote}}, $dep->{promote};
	    #- to simplify, a reference to list or standalone elements may be set in keep.
	    defined $dep->{keep} and push @{$state->{rejected}{$dep->{psel}->fullname}{backtrack}{keep}}, @{$dep->{keep}};
	} else {
	    #- the backtrack need to examine diff_provides promotion on $n.
	    with_db_unsatisfied_requires($urpm, $db, $state, $dep->{promote}, sub {
				      my ($p, @l) = @_;
				      #- typically a redo of the diff_provides code should be applied...
				      $urpm->resolve_rejected($db, $state, $p,
							      removed => 1,
							      unsatisfied => \@properties,
							      from => scalar $dep->{psel}->fullname,
							      why => { unsatisfied => \@l });
			      });
	}
    }

    #- some packages may have been removed because of selection of this one.
    #- the rejected flags should have been cleaned by disable_selected above.
    @properties;
}

#- close rejected (as urpme previously) for package to be removable without error.
sub resolve_rejected {
    my ($urpm, $db, $state, $pkg, %options) = @_;
    my @unsatisfied;

    $urpm->{debug_URPM}("resolve_rejected: " . $pkg->fullname) if $urpm->{debug_URPM};

    #- check if the package has already been asked to be rejected (removed or obsoleted).
    #- this means only add the new reason and return.
    if (! $state->{rejected}{$pkg->fullname}) {
	my @closure = $pkg;

	#- keep track of size of package which are finally removed.
	$state->{rejected}{$pkg->fullname}{size} = $pkg->size;
	foreach (qw(removed obsoleted)) {
	    $options{$_} and $state->{rejected}{$pkg->fullname}{$_} = $options{$_};
	}
	$options{closure_as_removed} and $options{removed} ||= delete $options{obsoleted};

	while (my $cp = shift @closure) {
	    #- close what requires this property, but check with selected package requiring old properties.
	    foreach ($cp->provides) {
		if (my ($n) = /^([^\s\[]*)/) {
		    foreach (keys %{$state->{whatrequires}{$n} || {}}) {
			my $pkg = $urpm->{depslist}[$_] or next;
			if (my @l = $urpm->unsatisfied_requires($db, $state, $pkg, name => $n)) {
			    #- a selected package requires something that is no more available
			    #- and should be tried to be re-selected if possible.
			    push @unsatisfied, @l;
			}
		    }
		    with_db_unsatisfied_requires($urpm, $db, $state, $n, sub {
			    my ($p, @l) = @_;
			    my $rv = $state->{rejected}{$p->fullname} ||= {};

			    #- keep track of what causes closure.
			    my %d; @d{@{$rv->{closure}{$pkg->fullname}{unsatisfied} ||= []}} = ();
			    push @{$rv->{closure}{$pkg->fullname}{unsatisfied}}, grep { ! exists $d{$_} } @l;

			    #- set removed and obsoleted level.
			    foreach (qw(removed obsoleted)) {
				$options{$_} && (! exists $rv->{$_} || $options{$_} <= $rv->{$_})
				    and $rv->{$_} = $options{$_};
			    }

			    #- continue the closure unless already examined.
			    exists $rv->{size} and return;
			    $rv->{size} = $p->size;

			    $p->pack_header; #- need to pack else package is no longer visible...
			    push @closure, $p;
		    });
		}
	    }
	}
    } else {
	#- the package has already been rejected.
	foreach (qw(removed obsoleted)) {
	    $options{$_} && (! exists $state->{rejected}{$pkg->fullname}{$_} ||
			     $options{$_} <= $state->{rejected}{$pkg->fullname}{$_})
	      and $state->{rejected}{$pkg->fullname}{$_} = $options{$_};
	}
    }

    $options{from} and $state->{rejected}{$pkg->fullname}{closure}{$options{from}} = $options{why};
    $options{unsatisfied} and push @{$options{unsatisfied}}, map { { required => $_, rejected => $pkg->fullname, } } @unsatisfied;
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
#-   keep_requested_flag :
#-   keep_unrequested_dependencies :
#-   keep :
#-   nodeps :
sub resolve_requested__no_suggests {
    my ($urpm, $db, $state, $requested, %options) = @_;
    my ($dep, @diff_provides, @properties, @selected);

    #- populate properties with backtrack informations.
    while (my ($r, $v) = each %$requested) {
	unless ($options{keep_requested_flag}) {
	    #- keep track of requested packages by propating the flag.
	    my $packages = $urpm->find_candidate_packages($r);
	    foreach (values %$packages) {
		foreach (@$_) {
		    $_->set_flag_requested;
		}
	    }
	}
	#- keep value to be available from selected hash.
	push @properties, { required => $r,
			    requested => $v,
			  };
    }

    #- for each dep property evaluated, examine which package will be obsoleted on $db,
    #- then examine provides that will be removed (which need to be satisfied by another
    #- package present or by a new package to upgrade), then requires not satisfied and
    #- finally conflicts that will force a new upgrade or a remove.
    do {
	while (defined ($dep = shift @properties)) {
	    #- in case of keep_unrequested_dependencies option is not set, we need to avoid
	    #- selecting packages if the source has been disabled.
	    if (exists $dep->{from} && !$options{keep_unrequested_dependencies}) {
		exists $state->{selected}{$dep->{from}->id} or next;
	    }

	    #- take the best choice possible.
	    my @chosen = $urpm->find_chosen_packages($db, $state, $dep->{required});

	    #- If no choice is found, this means that nothing can be possibly selected
	    #- according to $dep, so we need to retry the selection, allowing all
	    #- packages that conflict or anything similar to see which strategy can be
	    #- tried. Backtracking is used to avoid trying multiple times the same
	    #- packages. If multiple packages are possible, simply ask the user which
	    #- one to choose; else take the first one available.
	    if (!@chosen) {
		$urpm->{debug_URPM}("no packages match " . _id_to_name($urpm, $dep->{required}) . " (it may be in skip.list)") if $urpm->{debug_URPM};
		unshift @properties, $urpm->backtrack_selected($db, $state, $dep, %options);
		next; #- backtrack code choose to continue with same package or completely new strategy.
	    } elsif ($options{callback_choices} && @chosen > 1) {
		my @l = grep { ref $_ } $options{callback_choices}->($urpm, $db, $state, \@chosen, _id_to_name($urpm, $dep->{required}));
		$urpm->{debug_URPM}("replacing " . _id_to_name($urpm, $dep->{required}) . " with " . 
				    join(' ', map { $_->name } @l)) if $urpm->{debug_URPM};
		unshift @properties, map {
		    +{
			required => $_->id,
			choices => $dep->{required},
			exists $dep->{from} ? (from => $dep->{from}) : @{[]},
			exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
		    };
		} @l;
		next; #- always redo according to choices.
	    }

	    #- now do the real work, select the package.
	    my $pkg = shift @chosen;
	    if ($urpm->{debug_URPM} && $pkg->name ne _id_to_name($urpm, $dep->{required})) {
		$urpm->{debug_URPM}("chosen " . $pkg->fullname . " for " . _id_to_name($urpm, $dep->{required}));
		@chosen and $urpm->{debug_URPM}("  (it could also have chosen " . join(' ', map { scalar $_->fullname } @chosen));
	    }

	    #- cancel flag if this package should be cancelled but too late (typically keep options).
	    my @keep;

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
		my (%diff_provides);

		my $first;
		foreach ($pkg->name . " < " . $pkg->epoch . ":" . $pkg->version . "-" . $pkg->release, $pkg->obsoletes) {
		    if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\s*\[?([^\s\]]*)\s*([^\s\]]*)/) {
			if ($first++ && $n eq $pkg->name) {
			    #- ignore if this package obsoletes itself
			    #- otherwise this can cause havoc if: to_install=v3, installed=v2, v3 obsoletes < v2
			    next;
			}
			#- populate avoided entries according to what is selected.
			foreach my $p ($urpm->packages_providing($n)) {
			    if ($p->name eq $pkg->name) {
				#- all packages with the same name should now be avoided except when chosen.
				$p->fullname eq $pkg->fullname and next;
			    } else {
				#- in case of obsoletes, keep track of what should be avoided
				#- but only if package name equals the obsolete name.
				$p->name eq $n && (!$o || eval($p->compare($v) . $o . 0)) or next;
			    }
			    #- these packages are not yet selected, if they happen to be selected,
			    #- they must first be unselected.
			    $state->{rejected}{$p->fullname}{closure}{$pkg->fullname} ||= undef;
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
					    my @unselected_uninstalled = grep {
						!$_->flag_installed;
					    } $urpm->disable_selected($db, $state, $pkg);
					    $state->{unselected_uninstalled} = \@unselected_uninstalled;
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
				    if (my ($pn, $ps) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
					$diff_provides{$pn} = undef;
					foreach (grep { exists $state->{selected}{$_} }
					    keys %{$urpm->{provides}{$pn} || {}})
					{
					    my $pp = $urpm->{depslist}[$_];
					    foreach ($pp->provides) {
						/^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/ && $1 eq $pn
						    or next;
						$2 eq $ps
						    and delete $diff_provides{$pn};
					    }
					}
				    }
				}
			    });
		    }
		}

		push @diff_provides, map { +{ name => $_, pkg => $pkg } } keys %diff_provides;
	    }

	    #- all requires should be satisfied according to selected package, or installed packages.
	    if (my @l = $urpm->unsatisfied_requires($db, $state, $pkg)) {
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

	    #- examine conflicts, an existing package conflicting with this selection should
	    #- be upgraded to a new version which will be safe, else it should be removed.
	    foreach ($pkg->conflicts) {
		@keep and last;
		#- propagate conflicts to avoid
		if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\s*\[?([^\s\]]*)\s*([^\s\]]*)/) {
		    foreach my $p ($urpm->packages_providing($n)) {
			$pkg == $p and next;
			$p->name eq $n && (!$o || eval($p->compare($v) . $o . 0)) or next;
			$state->{rejected}{$p->fullname}{closure}{$pkg->fullname} = undef;
		    }
		}
		if (my ($file) = m!^(/[^\s\[]*)!) {
		    $db->traverse_tag('path', [ $file ], sub {
			@keep and return;
			my ($p) = @_;
			if ($options{keep}) {
			    push @keep, scalar $p->fullname;
			} else {
			    #- all these package should be removed.
			    $urpm->resolve_rejected(
				$db, $state, $p,
				removed => 1, unsatisfied => \@properties,
				from => scalar $pkg->fullname,
				why => { conflicts => $file },
			    );
			}
		    });
		} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
		    $db->traverse_tag('whatprovides', [ $name ], sub {
			@keep and return;
			my ($p) = @_;
			if ($p->provides_overlap($property)) {
			    $urpm->{debug_URPM}("installed package " . $p->fullname . " is conflicting with " . $pkg->fullname . " (Conflicts: $property)") if $urpm->{debug_URPM};

			    #- the existing package will conflict with the selection; check
			    #- whether a newer version will be ok, else ask to remove the old.
			    my $need_deps = $p->name . " > " . ($p->epoch ? $p->epoch . ":" : "") .
			    $p->version . "-" . $p->release;
			    my $packages = $urpm->find_candidate_packages($need_deps, avoided => $state->{rejected});
			    my $best = join('|', map { $_->id }
					      grep { ! $_->provides_overlap($property) }
						@{$packages->{$p->name}});

			    if (length $best) {
				$urpm->{debug_URPM}("promoting " . $urpm->{depslist}[$best]->fullname . " because of conflict above") if $urpm->{debug_URPM};
				unshift @properties, { required => $best, promote_conflicts => $name };
			    } else {
				if ($options{keep}) {
				    push @keep, scalar $p->fullname;
				} else {
				    #- no package has been found, we need to remove the package examined.
				    my $obsoleted;
				    #- force resolution (#12696, maybe #11885)
				    if (my $prev = delete $state->{rejected}{$p->fullname}) {
					$obsoleted = $prev->{obsoleted};
				    }
				    $urpm->resolve_rejected(
					$db, $state, $p,
					($obsoleted ? 'obsoleted' : 'removed') => 1,
					unsatisfied => \@properties,
					from => scalar $pkg->fullname,
					why => { conflicts => scalar $pkg->fullname },
				    );
				}
			    }
			}
		    });
		}
	    }

	    #- examine if an existing package does not conflict with this one.
	    $db->traverse_tag('whatconflicts', [ $pkg->name ], sub {
		@keep and return;
		my ($p) = @_;
		foreach my $property ($p->conflicts) {
		    if ($pkg->provides_overlap($property)) {
			if ($options{keep}) {
			    push @keep, scalar $p->fullname;
			} else {
			    #- all these packages should be removed.
			    $urpm->resolve_rejected($db, $state, $p,
			    removed => 1, unsatisfied => \@properties,
			    from => scalar $pkg->fullname,
			    why => { conflicts => $property });
			}
		    }
		}
	    });

	    #- keep existing package and therefore cancel current one.
	    if (@keep) {
		unshift @properties, $urpm->backtrack_selected($db, $state, +{ keep => \@keep, psel => $pkg }, %options);
	    }
	}
	if (defined ($dep = shift @diff_provides)) {
	    my ($n, $pkg) = ($dep->{name}, $dep->{pkg});
	    with_db_unsatisfied_requires($urpm, $db, $state, $n, sub {
				      my ($p, @l) = @_;
				      $urpm->{debug_URPM}($p->fullname . " is conflicting because of unsatisfied @l") if $urpm->{debug_URPM};

				      #- try if upgrading the package will be satisfying all the requires...
				      #- there is no need to avoid promoting epoch as the package examined is not
				      #- already installed.
				      my $packages = $urpm->find_candidate_packages($p->name, avoided => $state->{rejected});
				      my $best = join '|', map { $_->id }
					grep { ($_->name eq $p->name ||
						$_->obsoletes_overlap($p->name . " == " . $p->epoch . ":" . $p->version . "-" . $p->release))
						 && $_->fullname ne $p->fullname &&
						   $urpm->unsatisfied_requires($db, $state, $_, name => $n) == 0 }
					  map { @{$_ || []} } values %$packages;

				      if (length $best) {
					  $urpm->{debug_URPM}("promoting " . $urpm->{depslist}[$best]->fullname . " because of conflict above") if $urpm->{debug_URPM};
					  push @properties, { required => $best, promote => $n, psel => $pkg };
				      } else {
					  #- no package have been found, we may need to remove the package examined unless
					  #- there exists enough packages that provided the unsatisfied requires.
					  my @best;
					  foreach (@l) {
					      $packages = $urpm->find_candidate_packages($_,
											 nopromoteepoch => 1,
											 avoided => $state->{rejected});
					      $best = join('|',
							   map { $_->id }
							   grep { $_->fullname ne $p->fullname }
							   map { @{$_ || []} } values %$packages);
					      $best and push @best, $best;
					  }

					  if (@best == @l) {
					      $urpm->{debug_URPM}("promoting " . join(' ', map { scalar $urpm->{depslist}[$_]->fullname } @best) . " because of conflict above") if $urpm->{debug_URPM};
					      push @properties, map { +{ required => $_, promote => $n, psel => $pkg } } @best;
					  } else {
					      if ($options{keep}) {
						  unshift @properties, $urpm->backtrack_selected($db, $state,
												 { keep => [ scalar $p->fullname ],
												   psel => $pkg,
												 },
												 %options);
					      } else {
						  $urpm->resolve_rejected($db, $state, $p,
									  removed => 1,
									  unsatisfied => \@properties,
									  from => scalar $pkg->fullname,
									  why => { unsatisfied => \@l });
					      }
					  }
				      }
			      });
	}
    } while @diff_provides || @properties;

    #- return what has been selected by this call (not all selected hash which may be not empty
    #- previously. avoid returning rejected packages which weren't selectable.
    grep { exists $state->{selected}{$_->id} } @selected;
}

sub _id_to_name {
    my ($urpm, $dep) = @_;
    if ($dep =~ /^\d+/) {
	my $pkg = $urpm->{depslist}[$dep];
	$pkg && $pkg->name;
    } else {
	$dep;
    }
}

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

#- do the opposite of the above, unselect a package and extend
#- to any package not requested that is no longer needed by
#- any other package.
#- return the packages that have been deselected.
sub disable_selected {
    my ($urpm, $db, $state, @closure) = @_;
    my @unselected;

    #- iterate over package needing unrequested one.
    while (my $pkg = shift @closure) {
	exists $state->{selected}{$pkg->id} or next;

	#- keep a trace of what is deselected.
	push @unselected, $pkg;

	#- perform a closure on rejected packages (removed, obsoleted or avoided).
	my @closure_rejected = scalar $pkg->fullname;
	while (my $fullname = shift @closure_rejected) {
	    my @rejecteds = keys %{$state->{rejected}};
	    foreach (@rejecteds) {
		exists $state->{rejected}{$_} && exists $state->{rejected}{$_}{closure}{$fullname} or next;
		delete $state->{rejected}{$_}{closure}{$fullname};
		unless (%{$state->{rejected}{$_}{closure}}) {
		    delete $state->{rejected}{$_};
		    push @closure_rejected, $_;
		}
	    }
	}

	#- the package being examined has to be unselected.
	$pkg->set_flag_requested(0);
	$pkg->set_flag_required(0);
	delete $state->{selected}{$pkg->id};

	#- determine package that requires properties no longer available, so that they need to be
	#- unselected too.
	foreach my $n ($pkg->provides_nosense) {
	    foreach (keys %{$state->{whatrequires}{$n} || {}}) {
		my $p = $urpm->{depslist}[$_];
		exists $state->{selected}{$p->id} or next;
		if ($urpm->unsatisfied_requires($db, $state, $p, name => $n)) {
		    #- this package has broken dependencies and is selected.
		    push @closure, $p;
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
sub disable_selected_unrequested_dependencies {
    my ($urpm, $db, $state, @closure) = @_;
    my @unselected_closure;

    #- disable selected packages, then extend unselection to all required packages
    #- no longer needed and not requested.
    while (my @unselected = $urpm->disable_selected($db, $state, @closure)) {
	my %required;

	#- keep in the packages that had to be unselected.
	@unselected_closure or push @unselected_closure, @unselected;

	#- search for unrequested required packages.
	foreach (@unselected) {
	    foreach ($_->requires_nosense) {
		foreach my $pkg (grep {$_} $urpm->packages_providing($_)) {
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
		foreach (keys %{$state->{whatrequires}{$_} || {}}) {
		    my $p = $urpm->{depslist}[$_] or next;
		    exists $required{$p->id} and next;
		    $state->{selected}{$p->id} and $required{$pkg->id} = 1;
		}
	    }
	}

	#- now required values still undefined indicates packages than can be removed.
	@closure = map { $urpm->{depslist}[$_] } grep { !$required{$_} } keys %required;
    }

    @unselected_closure;
}

#- compute selected size by removing any removed or obsoleted package.
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
		$urpm->compute_flag($pkg, %options);
	    }
	}
    }

    #- now search packages which fullname match given regexps
    if (@regex) {
	foreach my $pkg (@{$urpm->{depslist}}) {
	    if (grep { $pkg->fullname =~ /$_/ } @regex) {
		$urpm->compute_flag($pkg, %options);
	    }
	}
    }
}

#- select packages to upgrade, according to package already registered.
#- by default, only takes best package and its obsoleted and compute
#- all installed or upgrade flag.
sub request_packages_to_upgrade {
    my ($urpm, $db, $_state, $requested, %options) = @_;

    my ($names, $obsoletes) = _request_packages_to_upgrade_1($urpm, %options) or return;
    _request_packages_to_upgrade_2($urpm, $db, $requested, $names, $obsoletes, %options);
}

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
	    if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*)\s*([^\s\]]*)/) {
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
		if (my ($n) = $property =~ /^([^\s\[]*)/) {
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

sub _sort_by_dependencies_get_graph {
    my ($urpm, $state, $l) = @_;
    my %edges;
    foreach my $id (@$l) {
	my $pkg = $urpm->{depslist}[$id];
	my @provides = map { keys %{$state->{whatrequires}{$_} || {}} } $pkg->provides_nosense;
	if (my $from = $state->{selected}{$id}{from}) {
	    unshift @provides, $from->id;
	}
	$edges{$id} = [ uniq(@provides) ];
    }
    \%edges;
}

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
	join('+', map { $urpm->{depslist}[$_]->name } @$_);
    } @sorted);
}

#- build transaction set for given selection
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

		$urpm->resolve_requested__no_suggests(
		    $db, $state->{transaction_state} ||= {},
		    \%requested,
		    keep_requested_flag => 1,
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
		    $urpm->{error}('transaction is too small: ' . join(' ', @bad_remove) . ' is rejected but it should not (current transaction: ' . join(' ', map { scalar $urpm->{depslist}[$_]->fullname } @upgrade) . ', requested: ' . join('+', map { scalar $urpm->{depslist}[$_]->fullname } @ids) . ')') if $urpm->{error};
		    $state->{transaction} = [];
		    last;
		}

		$urpm->{debug_URPM}(sprintf('transaction valid: remove=%s update=%s',
					    join(',', @remove),
					    join(',', map { $urpm->{depslist}[$_]->name } @upgrade))) if $urpm->{debug_URPM};
    
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
