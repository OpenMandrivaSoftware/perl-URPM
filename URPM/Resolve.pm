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
		my $satisfied = 0;
		foreach ($pkg->provides) {
		    ranges_overlap($_, $property) and ++$satisfied, last;
		}
		$satisfied and push @{$packages{$pkg->name}}, $pkg;
	    }
	}
    }
    \%packages;
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
		exists $state->{obsoleted}{$_} and next;
		exists $state->{ask_remove}{$_} and next;
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
				      exists $state->{obsoleted}{$p->fullname} and return;
				      exists $state->{ask_remove}{$p->fullname} and return;
				      $state->{cached_installed}{$n}{$p->fullname} = undef;
				      ++$satisfied;
				  });
	    } else {
		$db->traverse_tag('whatprovides', [ $n ], sub {
				      my ($p) = @_;
				      exists $state->{obsoleted}{$p->fullname} and return;
				      exists $state->{ask_remove}{$p->fullname} and return;
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

#- close ask_remove (as urpme previously) for package to be removable without error.
sub resolve_closure_ask_remove {
    my ($urpm, $db, $state, $pkg, $from, $why, $avoided) = @_;
    my @unsatisfied;

    #- allow default value for 'from' to be taken.
    $from ||= $pkg->fullname;

    #- keep track to avoided removed package.
    $avoided and $avoided->{$pkg->fullname} = undef;

    #- check if the package has already been asked to be removed,
    #- this means only add the new reason and return.
    unless ($state->{ask_remove}{$pkg->fullname}) {
	$state->{ask_remove}{$pkg->fullname} = { size    => $pkg->size,
						 closure => { $from => $why },
					       };

	my @removes = $pkg;
	while ($pkg = shift @removes) {
	    #- close what requires this property, but check with selected package requiring old properties.
	    foreach ($pkg->provides) {
		if (my ($n) = /^([^\s\[]*)/) {
		    foreach (keys %{$state->{whatrequires}{$n} || {}}) {
			my $pkg = $urpm->{depslist}[$_] or next;
			if (my @l = $urpm->unsatisfied_requires($db, $state, $pkg, name => $n, keep_state => 1)) {
			    #- a selected package requires something that is no more available
			    #- and should be tried to be re-selected.
			    push @unsatisfied, @l;
			}
		    }
		    $db->traverse_tag('whatrequires', [ $n ], sub {
					  my ($p) = @_;
					  if (my @l = $urpm->unsatisfied_requires($db, $state, $p, name => $n, keep_state => 1)) {
					      my $v = $state->{ask_remove}{$p->fullname} ||= {};

					      #- keep track to avoided removed package.
					      $avoided and $avoided->{$p->fullname} = undef;

					      #- keep track of what cause closure.
					      $v->{closure}{$pkg->fullname} = { unsatisfied => \@l };
					      exists $v->{size} and return;
					      $v->{size} = $p->size;

					      $p->pack_header; #- need to pack else package is no more visible...
					      push @removes, $p;
					  }
				      });
		}
	    }
	}
    } else {
	$state->{ask_remove}{$pkg->fullname}{closure}{$from} = $why;
    }

    @unsatisfied;
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
    my (@properties, @obsoleted, %requested, %avoided, $dep);

    #- keep in mind the requested id (if given) in order to prefer these packages
    #- on choices instead of anything other one.
    @properties = keys %$requested;
    foreach my $dep (@properties) {
	foreach (split '\|', $dep) {
	    $requested{$_} = $requested->{$dep};
	}
    }

    #- for each dep property evaluated, examine which package will be obsoleted on $db,
    #- then examine provides that will be removed (which need to be satisfied by another
    #- package present or by a new package to upgrade), then requires not satisfied and
    #- finally conflicts that will force a new upgrade or a remove.
    while (defined ($dep = shift @properties)) {
	my (@chosen, %diff_provides, $pkg, $allow);
	#- take the best package for each choices of same name.
	my $packages = $urpm->find_candidate_packages($dep);
	foreach (values %$packages) {
	    my ($best_requested, $best);
	    foreach (@$_) {
		exists $state->{selected}{$_->id} and $best_requested = $_, last;
		exists $avoided{$_->fullname} and next;
		if ($best_requested || exists $requested{$_->id}) {
		    if ($best_requested && $best_requested != $_) {
			$_->compare_pkg($best_requested) > 0 and $best_requested = $_;
		    } else {
			$best_requested = $_;
		    }
		} elsif ($best && $best != $_) {
		    $_->compare_pkg($best) > 0 and $best = $_;
		} else {
		    $best = $_;
		}
	    }
	    $_ = $best_requested || $best;
	}
	if (keys(%$packages) > 1) {
	    my (@chosen_requested_upgrade, @chosen_requested, @chosen_upgrade);
	    #- package should be prefered if one of their provides is referenced
	    #- in requested hash or package itself is requested (or required).
	    #- if there is no preference choose the first one (higher probability
	    #- of being chosen) by default and ask user.
	    foreach my $p (values %$packages) {
		$p or next; #- this could happen if no package are suitable for this arch.
		exists $state->{obsoleted}{$p->fullname} and next; #- avoid taking what is removed (incomplete).
		exists $state->{selected}{$p->id} and $pkg = $p, last; #- already selected package is taken.
		unless ($p->flag_upgrade || $p->flag_installed) {
		    #- assume for this small algorithm package to be upgradable.
		    $p->set_flag_upgrade;
		    $db->traverse_tag('name', [ $p->name ], sub {
					  my ($pp) = @_;
					  $p->set_flag_installed;
					  $p->flag_upgrade and $p->set_flag_upgrade($p->compare_pkg($pp) > 0);
				      });
		}
		if ($p->flag_installed) {
		    $p->flag_upgrade or $pkg = $p, last; #- already installed package is taken.
		    if (exists $requested{$p->id}) {
			push @chosen_requested_upgrade, $p;
		    } else {
			push @chosen_upgrade, $p;
		    }
		} else {
		    if (exists $requested{$p->id}) {
			push @chosen_requested, $p;
		    } else {
			push @chosen, $p;
		    }
		}
	    }
	    if (@chosen_requested_upgrade > 0 || @chosen_requested > 0) {
		@chosen = @chosen_requested_upgrade > 0 ? @chosen_requested_upgrade : @chosen_requested;
	    } else {
		@chosen_upgrade > 0 and @chosen = @chosen_upgrade;
	    }
	} else {
	    @chosen = values %$packages;
	}
	#- packages that requires locales-xxx and the corresponding locales is already installed
	#- should be prefered over packages that requires locales not installed.
	my (@chosen_good_locales, @chosen_bad_locales, @chosen_other);
	foreach (@chosen) {
	    $_ or next;
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
	@chosen = ((sort { $a->id <=> $b->id } @chosen_good_locales),
		   (sort { $a->id <=> $b->id } @chosen_other),
		   (sort { $a->id <=> $b->id } @chosen_bad_locales));
	if (!$pkg && $options{callback_choices} && @chosen > 1) {
	    unshift @properties, map { $_->id } grep { ref $_ } $options{callback_choices}->($urpm, $db, $state, \@chosen);
	    next; #- always redo according to choices.
	}
	$pkg ||= $chosen[0];
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
		#- the same or a more recent package is installed,
		#- but this package may be required explicitely, in such
		#- case we can ask to remove all the previous one and
		#- choose this one to install.
		$db->traverse_tag('name', [ $pkg->name ], sub {
				      my ($p) = @_;
				      if ($pkg->compare_pkg($p) < 0) {
					  $allow = ++$state->{oldpackage};
					  $options{keep_state} or
					    push @properties, $urpm->resolve_closure_ask_remove($db, $state, $p, $pkg->id,
												{ old_requested => 1 },
												\%avoided);
				      }
				  });
		#- if nothing has been removed, just ignore it.
		$allow or next;
	    }
	}

	#- keep in mind the package has be selected, remove the entry in requested input hasj,
	#- this means required dependencies have undef value in selected hash.
	#- requested flag is set only for requested package where value is not false.
	$state->{selected}{$pkg->id} = delete $requested->{$dep};

	$options{no_flag_update} or
	  ($state->{selected}{$pkg->id} ? $pkg->set_flag_requested : $pkg->set_flag_required);

	#- check if package is not already installed before trying to use it, compute
	#- obsoleted package too. this is valable only for non source package.
	if ($pkg->arch ne 'src') {
	    foreach ($pkg->name." < ".$pkg->epoch.":".$pkg->version."-".$pkg->release, $pkg->obsoletes) {
		if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\s*\[?([^\s\]]*)\s*([^\s\]]*)/) {
		    #- populate avoided entries according to what is selected.
		    foreach (keys %{$urpm->{provides}{$n} || {}}) {
			my $p = $urpm->{depslist}[$_];
			if ($p->name eq $pkg->name) {
			    #- all package with the same name should now be avoided except what is chosen.
			    $p->fullname eq $pkg->fullname or $avoided{$p->fullname} = $pkg->fullname;
			} else {
			    #- in case of obsoletes, keep track of what should be avoided
			    #- but only if package name equals the obsolete name.
			    $p->name eq $n && (!$o || eval($p->compare($v) . $o . 0)) or next;
			    $avoided{$p->fullname} = $pkg->fullname;
			}
		    }
		    #- examine rpm db too.
		    $db->traverse_tag('name', [ $n ], sub {
					  my ($p) = @_;
					  !$o || eval($p->compare($v) . $o . 0) or return;

					  if ($options{keep_state}) {
					      push @obsoleted, exists $state->{obsoleted}{$p->fullname} ?
						[ $p->fullname, $pkg->id ] : $p->fullname;
					  }
					  $state->{obsoleted}{$p->fullname}{$pkg->id} = undef;

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
					  my $packages = $urpm->find_candidate_packages($p->name, \%avoided);
					  my $best = join '|', map { $_->id }
					    grep { $urpm->unsatisfied_requires($db, $state, $_, name => $n) == 0 }
					      @{$packages->{$p->name}};

					  if (length $best) {
					      push @properties, $best;
					  } else {
					      #- no package have been found, we may need to remove the package examined unless
					      #- there exists a package that provided the unsatisfied requires.
					      my @best;
					      foreach (@l) {
						  $packages = $urpm->find_candidate_packages($_, \%avoided);
						  $best = join('|', map { $_->id } map { @{$_ || []} } values %$packages);
						  $best and push @best, $best;
					      }

					      if (@best == @l) {
						  push @properties, @best;
					      } else {
						  $options{keep_state} or
						    push @properties, $urpm->resolve_closure_ask_remove($db, $state, $p, $pkg->id,
													{ unsatisfied => \@l },
													\%avoided);
					      }
					  }
				      }
				  });
	    }
	}

	#- all requires should be satisfied according to selected package, or installed packages.
	push @properties, $urpm->unsatisfied_requires($db, $state, $pkg);

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
		    $avoided{$p->fullname} = $pkg->fullname;
		}
	    }
	    if (my ($file) = /^(\/[^\s\[]*)/) {
		$db->traverse_tag('path', [ $file ], sub {
				      my ($p) = @_;
				      #- all these packages should be removed.
				      $options{keep_state} or
					push @properties, $urpm->resolve_closure_ask_remove($db, $state, $p, $pkg->id,
											    { conflicts => $file },
											    \%avoided);
				  });
	    } elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
		$db->traverse_tag('whatprovides', [ $name ], sub {
				      my ($p) = @_;
				      if (grep { ranges_overlap($_, $property) } $p->provides) {
					  #- the existing package will conflicts with selection, check if a newer
					  #- version will be ok, else ask to remove the old.
					  my $need_deps = $p->name . " > " . ($p->epoch ? $p->epoch.":" : "") .
					                                     $p->version . "-" . $p->release;
					  my $packages = $urpm->find_candidate_packages($need_deps, \%avoided);
					  my $best = join '|', map { $_->id }
					    grep { ! grep { ranges_overlap($_, $property) } $_->provides }
					      @{$packages->{$p->name}};

					  if (length $best) {
					      push @properties, $best;
					  } else {
					      #- no package have been found, we need to remove the package examined.
					      $options{keep_state} or
						push @properties, $urpm->resolve_closure_ask_remove($db, $state, $p, $pkg->id,
												    { conflicts => $property },
												    \%avoided);
					  }
				      }
				  });
	    }
	}

	#- we need to check a selected package is not selected.
	#- if true, it should be unselected.
	unless ($options{keep_state}) {
	    foreach (keys %{$urpm->{provides}{$pkg->name} || {}}) {
		my $p = $urpm->{depslist}[$_];
		$p != $pkg && $p->name eq $pkg->name && ($p->flag_selected || exists $state->{selected}{$p->id}) or next;
		$state->{ask_unselect}{$pkg->id}{$p->id} = undef;
	    }
	}

	#- examine if an existing package does not conflicts with this one.
	$db->traverse_tag('whatconflicts', [ $pkg->name ], sub {
			      my ($p) = @_;
			      foreach my $property ($p->conflicts) {
				  if (grep { ranges_overlap($_, $property) } $pkg->provides) {
				      #- all these packages should be removed.
				      $options{keep_state} or
					push @properties, $urpm->resolve_closure_ask_remove($db, $state, $p, $pkg->id,
											    { conflicts => $property },
											    \%avoided);
				  }
			      }
			  });
    }

    if ($options{keep_state}) {
	#- clear state obsoleted according to saved obsoleted.
	foreach (@obsoleted) {
	    if (ref $_) {
		exists $state->{obsoleted}{$_->[0]} and delete $state->{obsoleted}{$_->[0]}{$_->[1]};
	    } else {
		delete $state->{obsoleted}{$_};
	    }
	}
    } else {
	#- obsoleted packages are no longer marked as being asked to be removed.
	delete @{$state->{ask_remove}}{map { /(.*)\.[^\.]*$/ && $1 } keys %{$state->{obsoleted}}};
    }

    #- return requested if not empty.
    %$requested && $requested;
}

#- do the opposite of the above, unselect a package and extend
#- to any package not requested that is no more needed by
#- any other package.
sub resolve_unrequested {
    my ($urpm, $db, $state, $unrequested, %options) = @_;
    my (@unrequested, %unrequested, $id);

    #- keep in mind unrequested package in order to allow unselection
    #- of requested package.
    @unrequested = keys %$unrequested;
    @unrequested{@unrequested} = ();

    #- iterate over package needing unrequested one.
    while (defined($id = shift @unrequested)) {
	my (%diff_provides, @clean_closure_ask_remove, $name);

	my $pkg = $urpm->{depslist}[$id];
	$pkg->flag_selected || exists $state->{unselected}{$pkg->id} or next;

	#- the package being examined has to be unselected.
	$options{no_flag_update} or
	  $pkg->set_flag_requested(0), $pkg->set_flag_required(0);
	$state->{unselected}{$pkg->id} = undef;

	#- state should be cleaned by any reference to it.
	foreach ($pkg->provides) {
	    $diff_provides{$_} = undef;
	}
	foreach ($pkg->name, $pkg->obsoletes_nosense) {
	    $db->traverse_tag('name', [ $_ ], sub {
				  my ($p) = @_;
				  if ($state->{obsoleted}{$p->fullname} && exists $state->{obsoleted}{$p->fullname}{$pkg->id}) {
				      #- found an obsoleted package, clean state.
				      delete $state->{obsoleted}{$p->fullname}{$pkg->id};
				      #- if this package has been obsoleted only by this one being unselected
				      #- compute diff_provides to found potentially requiring packages.
				      unless (%{$state->{obsoleted}{$p->fullname}}) {
					  delete $state->{obsoleted}{$p->fullname};
					  delete @diff_provides{$p->provides};
				      }
				  }
			      });
	}
	foreach (keys %{$state->{ask_remove}}) {
	    exists $state->{ask_remove}{$_}{closure}{$pkg->id} or next;
	    delete $state->{ask_remove}{$_}{closure}{$pkg->id};
	    unless (%{$state->{ask_remove}{$_}{closure}}) {
		delete $state->{ask_remove}{$_};
		push @clean_closure_ask_remove, $_;
	    }
	}
	while ($name = shift @clean_closure_ask_remove) {
	    foreach (keys %{$state->{ask_remove}}) {
		exists $state->{ask_remove}{$_}{closure}{$name} or next;
		delete $state->{ask_remove}{$_}{closure}{$name};
		unless (%{$state->{ask_remove}{$_}{closure}}) {
		    delete $state->{ask_remove}{$_};
		    push @clean_closure_ask_remove, $_;
		}
	    }
	}
	delete $state->{ask_unselect}{$pkg->id};

	#- determine package that requires properties no more available, so that they need to be
	#- unselected too.
	foreach (keys %diff_provides) {
	    if (my ($n) = /^([^\s\[]*)/) {
		$db->traverse_tag('whatrequires', [ $n ], sub {
				      my ($p) = @_;
				      if ($urpm->unsatisfied_requires($db, $state, $p, name => $n)) {
					  #- the package has broken dependencies, but it is already installed.
					  #- we can remove it (well this is problably not normal).
					  #TODO
					  $urpm->resolve_closure_ask_remove($db, $state, $p, $pkg->id,
									    { unrequested => 1 });
				      }
				  });
		#- check a whatrequires on selected packages directly.
		foreach (keys %{$state->{whatrequires}{$n} || {}}) {
		    my $p = $urpm->{depslist}[$_];
		    $p->flag_selected || exists $state->{unselected}{$p->id} or next;
		    if ($urpm->unsatisfied_requires($db, $state, $p, name => $n)) {
			#- this package has broken dependencies, but it is installed.
			#- just add it to unrequested.
			exists $unrequested{$p->id} or push @unrequested, $p->id;
			$unrequested{$p->id} = undef;
		    }
		}
	    }
	}

	#- determine among requires of this package if there is a package not requested but
	#- no more required.
	#TODO
    }

    #- return unrequested if not empty.
    %$unrequested && $unrequested;
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

1;
