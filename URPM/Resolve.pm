package URPM;

use strict;

#- find candidates packages from a require string (or id),
#- take care of direct choices using | sepatator.
sub find_candidate_packages {
    my ($urpm, $dep, $avoided) = @_;
    my %packages;

    foreach (split '\|', $dep) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->flag_skip and next;
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    $avoided && exists $avoided->{$pkg->fullname} and next;
	    push @{$packages{$pkg->name}}, $pkg;
	} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->flag_skip and next;
		$pkg->is_arch_compat or next;
		$avoided && exists $avoided->{$pkg->fullname} and next;
		#- check if at least one provide of the package overlap the property.
		my $satisfied = !$urpm->{provides}{$name}{$_};
		unless ($satisfied) {
		    foreach ($pkg->provides) {
			ranges_overlap($_, $property) and ++$satisfied, last;
		    }
		}
		$satisfied and push @{$packages{$pkg->name}}, $pkg;
	    }
	}
    }
    \%packages;
}

sub find_chosen_packages {
    my ($urpm, $db, $state, $dep) = @_;
    my %packages;

    #- search for possible packages, try to be as fast as possible, backtrack can be longer.
    foreach (split '\|', $dep) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->flag_skip || $state->{rejected}{$pkg->fullname} and next;
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    #- determine if this packages is better than a possibly previously chosen package.
	    $pkg->flag_selected || exists $state->{selected}{$pkg->id} and return $pkg;
	    if (my $p = $packages{$pkg->name}) {
		$pkg->flag_requested > $p->flag_requested ||
		  $pkg->flag_requested == $p->flag_requested && $pkg->compare_pkg($p) > 0 and $packages{$pkg->name} = $pkg;
	    } else {
		$packages{$pkg->name} = $pkg;
	    }
	} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->flag_skip || exists $state->{rejected}{$pkg->fullname} and next;
		$pkg->is_arch_compat or next;
		#- check if at least one provide of the package overlap the property (if sense are needed).
		my $satisfied = !$urpm->{provides}{$name}{$_};
		unless ($satisfied) {
		    foreach ($pkg->provides) {
			ranges_overlap($_, $property) and ++$satisfied, last;
		    }
		}
		if ($satisfied) {
		    #- determine if this packages is better than a possibly previously chosen package.
		    $pkg->flag_selected || exists $state->{selected}{$pkg->id} and return $pkg;
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
	my ($mode, @chosen, @chosen_good_locales, @chosen_bad_locales, @chosen_other);

	#- package should be prefered if one of their provides is referenced
	#- in requested hash or package itself is requested (or required).
	#- if there is no preference choose the first one (higher probability
	#- of being chosen) by default and ask user.
	foreach my $p (values(%packages)) {
	    unless ($p->flag_upgrade || $p->flag_installed) {
		#- assume for this small algorithm package to be upgradable.
		$p->set_flag_upgrade;
		$db->traverse_tag('name', [ $p->name ], sub {
				      my ($pp) = @_;
				      $p->set_flag_installed;
				      $p->flag_upgrade and $p->set_flag_upgrade($p->compare_pkg($pp) > 0);
				  });
	    }
	    if ($p->flag_requested && $p->flag_installed) {
		$mode < 3 and @chosen = ();
		$mode = 3;
	    } elsif ($p->flag_requested) {
		$mode < 2 and @chosen = ();
		$mode > 2 and next;
		$mode = 2;
	    } elsif ($p->flag_installed) {
		$mode < 1 and @chosen = ();
		$mode > 1 and next;
		$mode = 1;
	    } else {
		$mode and next;
	    }
	    push @chosen, $p;
	}

	#- packages that requires locales-xxx and the corresponding locales is already installed
	#- should be prefered over packages that requires locales not installed.
	foreach (@chosen) {
	    if (my ($specific_locales) = grep { /locales-/ && ! /locales-en/ } $_->requires_nosense) {
		if ((grep { $urpm->{depslist}[$_]->flag_available } keys %{$urpm->{provides}{$specific_locales}}) > 0 ||
		    $db->traverse_tag('name', [ $specific_locales ], undef) > 0) {
		    push @chosen_good_locales, $_;
		} else {
		    push @chosen_bad_locales, $_;
		}
	    } else {
		push @chosen_other, $_;
	    }
	}
	#- sort package in order to have best ones first (this means good locales, no locales, bad locales).
	return ((sort { $a->id <=> $b->id } @chosen_good_locales),
		(sort { $a->id <=> $b->id } @chosen_other),
		(sort { $a->id <=> $b->id } @chosen_bad_locales));
    }

    return values(%packages);
}

#- return unresolved requires of a package (a new one or a existing one).
sub unsatisfied_requires {
    my ($urpm, $db, $state, $pkg, %options) = @_;
    my %properties;

    #- all requires should be satisfied according to selected package, or installed packages.
  REQUIRES: foreach my $dep ($pkg->requires) {
	if (my ($n, $s) = $dep =~ /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
	    #- allow filtering on a given name (to speed up some search).
	    ! defined $options{name} || $n eq $options{name} or next REQUIRES;

	    #- avoid recomputing the same all the time.
	    exists $properties{$dep} and next REQUIRES;

	    #- check for installed package in the cache (only without sense to speed up)
	    foreach (keys %{$state->{cached_installed}{$n} || {}}) {
		exists $state->{rejected}{$_} and next;
		next REQUIRES;
	    }

	    #- check on selected package if a provide is satisfying the resolution (need to do the ops).
	    foreach (keys %{$urpm->{provides}{$n} || {}}) {
		exists $state->{selected}{$_} or next;
		my $p = $urpm->{depslist}[$_];
		if ($urpm->{provides}{$n}{$_}) {
		    #- sense information are used, this means we have to examine carrefully the provides.
		    foreach ($p->provides) {
			ranges_overlap($_, $dep) and next REQUIRES;
		    }
		} else {
		    next REQUIRES;
		}
	    }

	    #- check on installed system a package which is not obsoleted is satisfying the require.
	    my $satisfied = 0;
	    if ($n =~ /^\//) {
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
					      ranges_overlap($ps, $s) and ++$satisfied;
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

sub backtrack_selected {
    my ($urpm, $db, $state, $dep, %options) = @_;

    if (defined $dep->{required} && $options{callback_backtrack}) {
	#- search for all possible packages, first is to try the selection, then if it is
	#- impossible, backtrack the origin.
	my $packages = $urpm->find_candidate_packages($dep->{required});

	foreach (values %$packages) {
	    foreach (@$_) {
		#- avoid dead loop.
		exists $state->{backtrack}{selected}{$_->id} and next;
		#- a package if found is problably rejected or there is a problem.
		if ($state->{rejected}{$_->fullname}) {
		    if ($options{callback_backtrack}->($urpm, $db, $state, $_,
						       dep => $dep, alternatives => $packages, %options) <= 0) {
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

    #- at this point, dep cannot be resolved, this means we need to disable
    #- all selection tree, re-enabling removed and obsoleted packages as well.
    if (!$options{nodeps} && defined $dep->{from}) {
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
	push @{$state->{rejected}{$dep->{from}->fullname}{backtrack}{unsatisfied}}, $dep->{required};
    }

    #- some packages may have been removed because of selection of this one.
    #- the rejected flags should have been cleaned by disable_selected above.
    ();
}

#- close rejected (as urpme previously) for package to be removable without error.
sub resolve_rejected {
    my ($urpm, $db, $state, $pkg, %options) = @_;
    my @unsatisfied;

    #- check if the package has already been asked to be rejected (removed or obsoleted).
    #- this means only add the new reason and return.
    unless ($state->{rejected}{$pkg->fullname}) {
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
		    $db->traverse_tag('whatrequires', [ $n ], sub {
					  my ($p) = @_;
					  if (my @l = $urpm->unsatisfied_requires($db, $state, $p, name => $n)) {
					      my $v = $state->{rejected}{$p->fullname} ||= {};

					      #- keep track of what cause closure.
					      $v->{closure}{$pkg->fullname} = { unsatisfied => \@l };

					      #- set removed and obsoleted level.
					      foreach (qw(removed obsoleted)) {
						  $options{$_} && (! exists $v->{$_} || $options{$_} <= $v->{$_}) and
						    $v->{$_} = $options{$_};
					      }

					      #- continue the closure unless already examined.
					      exists $v->{size} and return;
					      $v->{size} = $p->size;

					      $p->pack_header; #- need to pack else package is no more visible...
					      push @closure, $p;
					  }
				      });
		}
	    }
	}
    } else {
	#- the package has already been rejected.
	$options{from} and $state->{rejected}{$pkg->fullname}{closure}{$options{from}} = $options{why};
	foreach (qw(removed obsoleted)) {
	    $options{$_} && (! exists $state->{rejected}{$pkg->fullname}{$_} ||
			     $options{$_} <= $state->{rejected}{$pkg->fullname}{$_})
	      and $state->{rejected}{$pkg->fullname}{$_} = $options{$_};
	}
    }

    $options{unsatisfied} and push @{$options{unsatisfied}}, map { { required => $_, rejected => $pkg->fullname, } } @unsatisfied;
}

#- resolve requested, keep resolution state to speed process.
#- a requested package is marked to be installed, once done, a upgrade flag or
#- installed flag is set according to needs of package.
#- other required package will have required flag set along with upgrade flag or
#- installed flag.
#- base flag should always been installed or upgraded.
#- the following options are recognized :
#-   check : check requires of installed packages.
sub resolve_requested {
    my ($urpm, $db, $state, $requested, %options) = @_;
    my ($dep, @properties, @selected);

    #- populate properties with backtrack informations.
    while (my ($r, $v) = each %$requested) {
	#- keep track of requested packages by propating the flag.
	my $packages = $urpm->find_candidate_packages($r);
	foreach (values %$packages) {
	    foreach (@$_) {
		$_->set_flag_requested;
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
    while (defined ($dep = shift @properties)) {
	#- in case of keep_unrequested_dependencies option is not set, we need to avoid
	#- selecting packages if the source has been disabled.
	if (exists $dep->{from} && !$options{keep_unrequested_dependencies}) {
	    $dep->{from}->flag_selected || exists $state->{selected}{$dep->{from}->id} or next;
	}

	#- take the best choice possible.
	my @chosen = $urpm->find_chosen_packages($db, $state, $dep->{required});

	#- if no choice are given, this means that nothing possible can be selected
	#- according to $dep, we need to retry the selection allowing all packages that
	#- conflicts or anything similar to see which strategy can be tried.
	#- backtracked is used to avoid trying multiple times the same packages.
	#- if multiple packages are possible, simply ask the user which one to choose.
	#- else take the first one available.
	if (!@chosen) {
	    unshift @properties, $urpm->backtrack_selected($db, $state, $dep, %options);
	    next; #- backtrack code choose to continue with same package or completely new strategy.
	} elsif ($options{callback_choices} && @chosen > 1) {
	    unshift @properties, map { +{ required => $_->id,
					  choices => $dep->{required},
					  exists $dep->{from} ? (from => $dep->{from}) : @{[]},
					  exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
					}
				   } grep { ref $_ } $options{callback_choices}->($urpm, $db, $state, \@chosen);
	    next; #- always redo according to choices.
	}

	#- now do the real work, select the package.
	my ($pkg) = @chosen;
	!$pkg || $pkg->flag_selected || exists $state->{selected}{$pkg->id} and next;

	if ($pkg->arch eq 'src') {
	    $pkg->set_flag_upgrade;
	} else {
	    unless ($pkg->flag_upgrade || $pkg->flag_installed) {
		#- assume for this small algorithm package to be upgradable.
		$pkg->set_flag_upgrade;
		$db->traverse_tag('name', [ $pkg->name ], sub {
				      my ($p) = @_;
				      $pkg->set_flag_installed; #- there is at least one package installed (whatever its version).
				      $pkg->flag_upgrade and $pkg->set_flag_upgrade($pkg->compare_pkg($p) > 0);
				  });
	    }
	    if ($pkg->flag_installed && !$pkg->flag_upgrade) {
		my $allow;
		#- the same or a more recent package is installed,
		#- but this package may be required explicitely, in such
		#- case we can ask to remove all the previous one and
		#- choose this one to install.
		$db->traverse_tag('name', [ $pkg->name ], sub {
				      my ($p) = @_;
				      if ($pkg->compare_pkg($p) < 0) {
					  $allow = ++$state->{oldpackage};
					  #- avoid recusive rejects, else everything may be removed.
					  my $v = $state->{rejected}{$p->fullname} ||= {};
					  $v->{closure}{$pkg->fullname} = { old_requested => 1 };
					  $v->{removed} = 1;
				      }
				  });
		#- if nothing has been removed, just ignore it.
		$allow or next;
	    }
	}

	#- keep in mind the package has be selected, remove the entry in requested input hash,
	#- this means required dependencies have undef value in selected hash.
	#- requested flag is set only for requested package where value is not false.
	push @selected, $pkg;
	$state->{selected}{$pkg->id} = { exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
					 exists $dep->{from} ? (from => $dep->{from}) : @{[]},
				       };

	$pkg->set_flag_required;

	#- check if package is not already installed before trying to use it, compute
	#- obsoleted package too. this is valable only for non source package.
	if ($pkg->arch ne 'src') {
	    my (%diff_provides);

	    foreach ($pkg->name." < ".$pkg->epoch.":".$pkg->version."-".$pkg->release, $pkg->obsoletes) {
		if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\s*\[?([^\s\]]*)\s*([^\s\]]*)/) {
		    #- populate avoided entries according to what is selected.
		    foreach (keys %{$urpm->{provides}{$n} || {}}) {
			my $p = $urpm->{depslist}[$_];
			if ($p->name eq $pkg->name) {
			    #- all package with the same name should now be avoided except what is chosen.
			    $p->fullname eq $pkg->fullname and next;
			} else {
			    #- in case of obsoletes, keep track of what should be avoided
			    #- but only if package name equals the obsolete name.
			    $p->name eq $n && (!$o || eval($p->compare($v) . $o . 0)) or next;
			}
			#- these packages are not yet selected, if they happens to be selected,
			#- they must first be unselected.
			$state->{rejected}{$p->fullname}{closure}{$pkg->fullname} ||= undef;
		    }
		    #- examine rpm db too.
		    $db->traverse_tag('name', [ $n ], sub {
					  my ($p) = @_;
					  !$o || eval($p->compare($v) . $o . 0) or return;

					  #- do not propagate now the broken dependencies as they are
					  #- computed later.
					  my $v = $state->{rejected}{$p->fullname} ||= {};
					  $v->{closure}{$pkg->fullname} = undef;
					  $v->{obsoleted} = 1;
					  $v->{size} = $p->size;

					  foreach ($p->provides) {
					      #- check differential provides between obsoleted package and newer one.
					      if (my ($pn, $ps) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
						  $diff_provides{$pn} = undef;
						  foreach (grep { exists $state->{selected}{$_} }
							   keys %{$urpm->{provides}{$pn} || {}}) {
						      my $pp = $urpm->{depslist}[$_];
						      foreach ($pp->provides) {
							  /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/ && $1 eq $pn or next;
							  $2 eq $ps and delete $diff_provides{$pn};
						      }
						  }
					      }
					  }
				      });
		}
	    }

	    foreach my $n (keys %diff_provides) {
		$db->traverse_tag('whatrequires', [ $n ], sub {
				      my ($p) = @_;
				      if (my @l = $urpm->unsatisfied_requires($db, $state, $p)) {
					  #- try if upgrading the package will be satisfying all the requires
					  #- else it will be necessary to ask the user for removing it.
					  my $packages = $urpm->find_candidate_packages($p->name, $state->{rejected});
					  my $best = join '|', map { $_->id }
					    grep { $urpm->unsatisfied_requires($db, $state, $_, name => $n) == 0 }
					      @{$packages->{$p->name}};

					  if (length $best) {
					      push @properties, { required => $best, promote => $n };
					  } else {
					      #- no package have been found, we may need to remove the package examined unless
					      #- there exists a package that provided the unsatisfied requires.
					      my @best;
					      foreach (@l) {
						  $packages = $urpm->find_candidate_packages($_, $state->{rejected});
						  $best = join('|', map { $_->id } map { @{$_ || []} } values %$packages);
						  $best and push @best, $best;
					      }

					      if (@best == @l) {
						  push @properties, map { +{ required => $_, promote => $n } } @best;
					      } else {
						  $urpm->resolve_rejected($db, $state, $p,
									  removed => 1, unsatisfied => \@properties,
									  from => scalar $pkg->fullname, why => { unsatisfied => \@l });
					      }
					  }
				      }
				  });
	    }
	}

	#- all requires should be satisfied according to selected package, or installed packages.
	push @properties, map { +{ required => $_, from => $pkg } } $urpm->unsatisfied_requires($db, $state, $pkg);

	#- keep in mind what is requiring each item (for unselect to work).
	foreach ($pkg->requires_nosense) {
	    $state->{whatrequires}{$_}{$pkg->id} = undef;
	}

	#- examine conflicts, an existing package conflicting with this selection should
	#- be upgraded to a new version which will be safe, else it should be removed.
	foreach ($pkg->conflicts) {
	    #- propagate conflicts to avoided.
	    if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\s*\[?([^\s\]]*)\s*([^\s\]]*)/) {
		foreach (keys %{$urpm->{provides}{$n} || {}}) {
		    my $p = $urpm->{depslist}[$_];
		    $p->name eq $n && (!$o || eval($p->compare($v) . $o . 0)) or next;
		    $state->{rejected}{$p->fullname}{closure}{$pkg->fullname} = undef;
		}
	    }
	    if (my ($file) = /^(\/[^\s\[]*)/) {
		$db->traverse_tag('path', [ $file ], sub {
				      my ($p) = @_;
				      #- all these packages should be removed.
				      $urpm->resolve_rejected($db, $state, $p,
							      removed => 1, unsatisfied => \@properties,
							      from => scalar $pkg->fullname, why => { conflicts => $file });
				  });
	    } elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
		$db->traverse_tag('whatprovides', [ $name ], sub {
				      my ($p) = @_;
				      if (grep { ranges_overlap($_, $property) } $p->provides) {
					  #- the existing package will conflicts with selection, check if a newer
					  #- version will be ok, else ask to remove the old.
					  my $need_deps = $p->name . " > " . ($p->epoch ? $p->epoch.":" : "") .
					                                     $p->version . "-" . $p->release;
					  my $packages = $urpm->find_candidate_packages($need_deps, $state->{rejected});
					  my $best = join '|', map { $_->id }
					    grep { ! grep { ranges_overlap($_, $property) } $_->provides }
					      @{$packages->{$p->name}};

					  if (length $best) {
					      push @properties, { required => $best, promote_conflicts => $name };
					  } else {
					      #- no package have been found, we need to remove the package examined.
					      $urpm->resolve_rejected($db, $state, $p,
								      removed => 1, unsatisfied => \@properties,
								      from => scalar $pkg->fullname, why => { conflicts => $property });
					  }
				      }
				  });
	    }
	}

	#- examine if an existing package does not conflicts with this one.
	$db->traverse_tag('whatconflicts', [ $pkg->name ], sub {
			      my ($p) = @_;
			      foreach my $property ($p->conflicts) {
				  if (grep { ranges_overlap($_, $property) } $pkg->provides) {
				      #- all these packages should be removed.
				      $urpm->resolve_rejected($db, $state, $p,
							      removed => 1, unsatisfied => \@properties,
							      from => scalar $pkg->fullname, why => { conflicts => $property });
				  }
			      }
			  });
    }

    #- return what has been selected by this call (not all selected hash which may be not emptry
    #- previously. avoid returning rejected package which have not be selectable.
    grep { exists $state->{selected}{$_->id} } @selected;
}

#- do the opposite of the above, unselect a package and extend
#- to any package not requested that is no more needed by
#- any other package.
#- return the packages that have been deselected.
sub disable_selected {
    my ($urpm, $db, $state, @closure) = @_;
    my @unselected;

    #- iterate over package needing unrequested one.
    while (my $pkg = shift @closure) {
	$pkg->flag_selected || exists $state->{selected}{$pkg->id} or next;

	#- keep a trace of what is deselected.
	push @unselected, $pkg;

	#- do a closure on rejected packages (removed, obsoleted or avoided).
	my @closure_rejected = $pkg->fullname;
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

	#- determine package that requires properties no more available, so that they need to be
	#- unselected too.
	foreach my $n ($pkg->provides_nosense) {
	    foreach (keys %{$state->{whatrequires}{$n} || {}}) {
		my $p = $urpm->{depslist}[$_];
		$p->flag_selected || exists $state->{selected}{$p->id} or next;
		if ($urpm->unsatisfied_requires($db, $state, $p, name => $n)) {
		    #- this package has broken dependencies and is selected.
		    push @closure, $p;
		}
	    }
	}

	#- the package being examined has to be unselected.
	$pkg->set_flag_requested(0);
	$pkg->set_flag_required(0);
	delete $state->{selected}{$pkg->id};

	#- clean whatrequires hash.
	foreach ($pkg->requires_nosense) {
	    delete $state->{whatrequires}{$_}{$pkg->id};
	    %{$state->{whatrequires}{$_}} or delete $state->{whatrequires}{$_};
	}
    }

    #- return all unselected packages.
    @unselected;
}

#- determine dependencies that can safely been removed and are not requested,
sub disable_selected_unrequested_dependencies {
    my ($urpm, $db, $state, @closure) = @_;
    my @unselected_closure;

    #- disable selected packages, then extend unselection to all required packages
    #- no more needed and not requested.
    while (my @unselected = $urpm->disable_selected($db, $state, @closure)) {
	my %required;

	#- keep in the packages that have needed to be unselected.
	@unselected_closure or push @unselected_closure, @unselected;

	#- search for unrequested required packages.
	foreach (@unselected) {
	    foreach ($_->requires_nosense) {
		foreach (keys %{$urpm->{provides}{$_} || {}}) {
		    my $pkg = $urpm->{depslist}[$_] or next;
		    $pkg->flag_selected || exists $state->{selected}{$pkg->id} or next;
		    $pkg->flag_requested and next;
		    $required{$pkg->id} = undef;
		}
	    }
	}

	#- check required packages are not needed by another selected package.
	foreach (keys %required) {
	    my $pkg = $urpm->{depslist}[$_] or next;
	    foreach ($pkg->provides_nosense) {
		foreach (keys %{$state->{whatrequires}{$_}}) {
		    my $p = $urpm->{depslist}[$_] or next;
		    exists $required{$p->id} and next;
		    $p->flag_selected and $required{$pkg->id} = 1;
		}
	    }
	}

	#- now required values still undefined indicates packages than can be removed.
	@closure = map { $urpm->{depslist}[$_] } grep { !$required{$_} } keys %required;
    }

    @unselected_closure;
}

#- compute installed flags for all package in depslist.
sub compute_installed_flags {
    my ($urpm, $db) = @_;
    my %sizes;

    #- first pass to initialize flags installed and upgrade for all package.
    foreach (@{$urpm->{depslist}}) {
	$_->is_arch_compat or next;
	$_->flag_upgrade || $_->flag_installed or $_->set_flag_upgrade;
    }

    #- second pass to set installed flag and clean upgrade flag according to installed packages.
    $db->traverse(sub {
		      my ($p) = @_;
		      #- keep mind of sizes of each packages.
		      $sizes{$p->name} += $p->size;
		      #- compute flags.
		      foreach (keys %{$urpm->{provides}{$p->name} || {}}) {
			  my $pkg = $urpm->{depslist}[$_];
			  $pkg->is_arch_compat && $pkg->name eq $p->name or next;
			  #- compute only installed and upgrade flags.
			  $pkg->set_flag_installed; #- there is at least one package installed (whatever its version).
			  $pkg->flag_upgrade and $pkg->set_flag_upgrade($pkg->compare_pkg($p) > 0);
		      }
		  });

    \%sizes;
}

#- compute skip flag according to hash describing package to remove
#- $skip is a hash reference described as follow :
#-   key is package name or regular expression on fullname if /.../
#-   value is reference to hash indicating sense information ({ '' => undef } if none).
#- options hash :
#-   callback : sub to be called for each package with skip flag activated,
sub compute_skip_flags {
    my ($urpm, $skip, %options) = @_;

    #- avoid losing our time.
    %$skip or return;

    foreach my $pkg (@{$urpm->{depslist}}) {
	#- check if fullname is matching a regexp.
	if (grep { exists($skip->{$_}{''}) && /^\/(.*)\/$/ && $pkg->fullname =~ /$1/ } keys %$skip) {
	    #- a single selection on fullname using a regular expression.
	    unless ($pkg->flag_skip) {
		$pkg->set_flag_skip(1);
		$options{callback} and $options{callback}->($urpm, $pkg, %options);
	    }
	} else {
	    #- check if a provides match at least one package.
	    foreach ($pkg->provides) {
		if (my ($n, $s) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
		    foreach my $sn ($n, grep { /^\/(.*)\/$/ && $n =~ /$1/ } keys %$skip) {
			foreach (keys %{$skip->{$sn} || {}}) {
			    if (URPM::ranges_overlap($_, $s) && !$pkg->flag_skip) {
				$pkg->set_flag_skip(1);
				$options{callback} and $options{callback}->($urpm, $pkg, %options);
			    }
			}
		    }
		}
	    }
	}
    }
}

#- select packages to upgrade, according to package already registered.
#- by default, only takes best package and its obsoleted and compute
#- all installed or upgrade flag.
sub request_packages_to_upgrade {
    my ($urpm, $db, $_state, $requested, %options) = @_;
    my (%provides, %names, %skip, %requested, %obsoletes, @obsoleters);

    #- build direct access to best package according to name.
    foreach my $pkg (@{$urpm->{depslist}}) {
	defined $options{start} && $pkg->id < $options{start} and next;
	defined $options{end}   && $pkg->id > $options{end}   and next;

	if ($pkg->is_arch_compat) {
	    foreach ($pkg->provides) {
		if (my ($n, $evr) = /^([^\s\[]*)(?:\[\*\])?\[?=+\s*([^\s\]]*)/) {
		    if ($provides{$n}) {
			foreach ($provides{$n}->provides) {
			    if (my ($pn, $pevr) = /^([^\s\[]*)(?:\[\*\])?\[?=+\s*([^\s\]]*)/) {
				$pn eq $n or next;
				if (ranges_overlap("< $evr", "== $pevr")) {
				    #- this package looks like too old ?
				    $provides{$n}->name ne $pkg->name and $skip{$provides{$n}->name} = undef;
				    $provides{$n} = $pkg;
				}
				last;
			    }
			}
		    } else {
			$provides{$n} = $pkg;
		    }
		}
	    }

	    my $p = $names{$pkg->name};
	    if ($p) {
		if ($pkg->compare_pkg($p) > 0) {
		    $names{$pkg->name} = $pkg;
		}
	    } else {
		$names{$pkg->name} = $pkg;
	    }
	}
    }

    #- clean direct access, a package in names should have 
    #- check consistency with obsoletes of eligible package.
    #- it is important not to select a package wich obsolete
    #- an old one.
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

    #- now we can examine all existing packages to find packages to upgrade.
    $db->traverse(sub {
		      my ($p) = @_;
		      #- first try with package using the same name.
		      #- this will avoid selecting all packages obsoleting an old one.
		      if (my $pkg = $names{$p->name}) {
			  unless ($pkg->flag_upgrade || $pkg->flag_installed) {
			      $pkg->set_flag_installed; #- there is at least one package installed (whatever its version).
			      $pkg->set_flag_upgrade;
			  }
			  $pkg->flag_upgrade and $pkg->set_flag_upgrade($pkg->compare_pkg($p) > 0);
			  #- keep in mind the package is requested.
			  if ($pkg->flag_upgrade) {
			      $requested{$p->name} = undef;
			  } else {
			      delete $names{$p->name};
			  }
		      }

		      #- check provides of existing package to see if a obsolete
		      #- may allow selecting it.
		      foreach my $property ($p->provides) {
			  #- only real provides should be taken into account, this means internal obsoletes
			  #- should be avoided.
			  unless (grep { ranges_overlap($property, $_) } $p->obsoletes) {
			      if (my ($n) = $property =~ /^([^\s\[]*)/) {
				  foreach my $pkg (@{$obsoletes{$n} || []}) {
				      next if $pkg->name eq $p->name || $p->name ne $n || !$names{$pkg->name};
				      foreach ($pkg->obsoletes) {
					  if (ranges_overlap($property, $_)) {
					      #- the package being examined can be obsoleted.
					      #- do not set installed and provides flags.
					      push @obsoleters, $pkg;
					      return;
					  }
				      }
				  }
			      }
			  }
		      }
		  });

    #- examine all obsoleters packages, compute installer and upgrade flag if needed.
    foreach my $pkg (@obsoleters) {
	next if !$names{$pkg->name};
	unless ($pkg->flag_upgrade || $pkg->flag_installed) {
	    #- assume for this small algorithm package to be upgradable.
	    $pkg->set_flag_upgrade;
	    $db->traverse_tag('name', [ $pkg->name ], sub {
				  my ($p) = @_;
				  $pkg->set_flag_installed; #- there is at least one package installed (whatever its version).
				  $pkg->flag_upgrade and $pkg->set_flag_upgrade($pkg->compare_pkg($p) > 0);
			      });
	}
	if ($pkg->flag_installed && !$pkg->flag_upgrade) {
	    delete $names{$pkg->name};
	} else {
	    $requested{$pkg->name} = undef;
	}
    }

    #- examine all packages which may be conflicting, it a package conflicts, it should not be requested.
    my @names = map { $_->name." == ".$_->epoch.":".$_->version."-".$_->release } values %names;
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

#- compatiblity method which are going to be removed.
sub resolve_closure_ask_remove {
    my ($urpm, $db, $state, $pkg, $from, $why, $avoided) = @_;

    print STDERR "calling obsoleted method URPM::resolve_closure_ask_remove\n";

    my @unsatisfied;
    $urpm->resolve_rejected($db, $state, $pkg, from => $from, why => $why, removed => 1, unsatisfied => \@unsatisfied);

    #- rebuild correctly ask_remove hash.
    delete $state->{ask_remove};
    foreach (keys %{$state->{rejected}}) {
	$state->{rejected}{$_}{obsoleted} and next;
	$state->{rejected}{$_}{removed} or next;

	$state->{ask_remove}{$_}{closure} = $state->{rejected}{$_}{closure}; # fullname are not converted back to id as expected.
	$state->{ask_remove}{$_}{size} = $state->{rejected}{$_}{size};
    }

    @unsatisfied;
}
sub resolve_unrequested {
    my ($urpm, $db, $state, $unrequested, %options) = @_;

    print STDERR "calling obsoleted method URPM::resolve_unrequested\n";

    my @l = $urpm->disable_selected($db, $state, map { $urpm->{depslist}[$_] } keys %$unrequested);

    #- build unselected accordingly.
    delete $state->{unselected};
    foreach (@l) {
	delete $unrequested->{$_->id};
	$state->{unselected}{$_->id} = undef;
    }

    #- use return value of old method.
    %$unrequested && $unrequested;
}

1;
