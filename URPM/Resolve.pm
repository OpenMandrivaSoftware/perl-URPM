package URPM;

use strict;

#- find candidates packages from a require string (or id),
#- take care of direct choices using | sepatator.
sub find_candidate_packages {
    my ($urpm, $dep) = @_;
    my %packages;

    foreach (split '\|', $dep) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    push @{$packages{$pkg->name}}, $pkg;
	} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->is_arch_compat or next;
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
    my ($urpm, $db, $state, $pkg, $name) = @_;
    my %properties;

    #- all requires should be satisfied according to selected package, or installed packages.
    foreach ($pkg->requires) {
	if (my ($n, $s) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
	    #- allow filtering on a given name (to speed up some search).
	    ! defined $name || $n eq $s or next;

	    #- avoid recomputing the same all the time.
	    exists $properties{$_} || $state->{installed}{$_} and next;

	    #- keep track if satisfied.
	    my $satisfied = 0;
	    #- check on selected package if a provide is satisfying the resolution (need to do the ops).
	    foreach my $sense (keys %{$state->{provided}{$n} || {}}) {
		ranges_overlap($sense, $s) and ++$satisfied, last;
	    }
	    #- check on installed system a package which is not obsoleted is satisfying the require.
	    unless ($satisfied) {
		if ($n =~ /^\//) {
		    $db->traverse_tag('path', [ $n ], sub {
					  my ($p) = @_;
					  exists $state->{obsoleted}{$p->fullname} and return;
					  ++$satisfied;
				      });
		} else {
		    $db->traverse_tag('whatprovides', [ $n ], sub {
					  my ($p) = @_;
					  exists $state->{obsoleted}{$p->fullname} and return;
					  foreach ($p->provides) {
					      $state->{installed}{$_}{$p->fullname} = undef;
					      if (my ($pn, $ps) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
						  $pn eq $n or next;
						  ranges_overlap($ps, $s) and ++$satisfied;
					      }
					  }
				      });
		}
	    }
	    #- if nothing can be done, the require should be resolved.
	    $satisfied or $properties{$_} = undef;
	}
    }
    keys %properties;
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
    my ($urpm, $db, $state, %options) = @_;
    my (@properties, %requested, $dep);

    #- for each dep property evaluated, examine which package will be obsoleted on $db,
    #- then examine provides that will be removed (which need to be satisfied by another
    #- package present or by a new package to upgrade), then requires not satisfied and
    #- finally conflicts that will force a new upgrade or a remove.
    @properties = keys %{$state->{requested}};
    foreach my $dep (@properties) {
	foreach (split '\|', $dep) {
	    $requested{$_} = $state->{requested}{$dep};
	}
    }
    while (defined ($dep = shift @properties)) {
	my (@chosen_requested, @chosen_upgrade, @chosen, %diff_provides, $pkg);
	#- take the best package for each choices of same name.
	my $packages = $urpm->find_candidate_packages($dep);
	foreach (values %$packages) {
	    my $best;
	    foreach (@$_) {
		if ($best && $best != $_) {
		    $_->compare_pkg($best) > 0 and $best = $_;
		} else {
		    $best = $_;
		}
	    }
	    $_ = $best;
	}
	if (keys(%$packages) > 1) {
	    #- package should be prefered if one of their provides is referenced
	    #- in requested hash or package itself is requested (or required).
	    #- if there is no preference choose the first one (higher probability
	    #- of being chosen) by default and ask user.
	    foreach my $p (values %$packages) {
		$p or next; #- this could happen if no package are suitable for this arch.
		exists $state->{selected}{$p->id} and $pkg = $p, last; #- already selected package is taken.
		if (exists $requested{$p->id}) {
		    push @chosen_requested, $p;
		} elsif ($db->traverse_tag('name', [ $p->name ], undef) > 0) {
		    push @chosen_upgrade, $p;
		} else {
		    push @chosen, $p;
		}
	    }
	    @chosen_requested > 0 and @chosen = @chosen_requested;
	    @chosen_requested == 0 and @chosen_upgrade > 0 and @chosen = @chosen_upgrade;
	} else {
	    @chosen = values %$packages;
	}
	if (!$pkg && $options{callback_choices} && @chosen > 1) {
	    $pkg = $options{callback_choices}->($urpm, $db, $state, \@chosen);
	    $pkg or next; #- callback may decide to not continue (or state is already updated).
	}
	$pkg ||= $chosen[0];
	$pkg && !$pkg->flag_requested && !$pkg->flag_required or next;

	#- keep in mind the package has be selected.
	$pkg->set_flag_requested($state->{selected}{$pkg->id} = delete $requested{$dep});
	$pkg->set_flag_required(!$pkg->flag_requested);

	#- check if package is not already installed before trying to use it, compute
	#- obsoleted package too. this is valable only for non source package.
	if ($pkg->arch ne 'src') {
	    $pkg->flag_installed and delete $state->{selected}{$pkg->id}, next;
	    unless ($pkg->flag_upgrade) {
		$db->traverse_tag('name', [ $pkg->name ], sub {
				      my ($p) = @_;
				      $pkg->flag_installed or
					$pkg->set_flag_installed($pkg->compare_pkg($p) <= 0);
				  });
		$pkg->set_flag_upgrade(!$pkg->flag_installed);
	    }
	    $pkg->flag_installed and delete $state->{selected}{$pkg->id}, next;

	    #- keep in mind the provides of this package, so that future requires can be satisfied
	    #- with this package potentially.
	    foreach ($pkg->provides) {
		if (my ($n, $s) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
		    $state->{provided}{$n}{$s}{$pkg->id} = undef;
		}
	    }

	    foreach ($pkg->name, $pkg->obsoletes) {
		if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*)\s*([^\s\]]*)/) {
		    $db->traverse_tag('name', [ $n ], sub {
					  my ($p) = @_;
					  !$o || eval($p->compare($v) . $o . 0) or return;

					  $state->{obsoleted}{$p->fullname}{$pkg->id} = undef;

					  foreach ($p->provides) {
					      #- clean installed property.
					      if (my ($ip) = $state->{installed}{$_}) {
						  delete $ip->{$p->fullname};
						  %$ip or delete $state->{installed}{$_};
					      }
					      #- check differential provides between obsoleted package and newer one.
					      if (my ($pn, $ps) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
						  ($state->{provided}{$pn} || {})->{$ps} or $diff_provides{$n} = undef;
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
					  #- else it will be necessary to ask hte user for removing it.
					  my $packages = $urpm->find_candidate_packages($p->name);
					  my $best;
					  foreach (grep { $urpm->unsatisfied_requires($db, $state, $_, $n) == 0 }
						   @{$packages->{$p->name}}) {
					      if ($best && $best != $_) {
						  $_->compare_pkg($best) > 0 and $best = $_;
					      } else {
						  $best = $_;
					      }
					  }
					  if ($best) {
					      push @properties, $best->id;
					  } else {
					      #- no package have been found, we need to remove the package examined.
					      push @{$state->{ask_remove}{$p->fullname}}, { unsatisfied => \@l, pkg => $pkg };
					  }
				      }
				  });
	    }
	}

	#- all requires should be satisfied according to selected package, or installed packages.
	push @properties, $urpm->unsatisfied_requires($db, $state, $pkg);

	#- examine conflicts, an existing package conflicting with this selection should
	#- be upgraded to a new version which will be safe, else it should be removed.
	foreach ($pkg->conflicts) {
	    if (my ($file) = /^(\/[^\s\[]*)/) {
		$db->traverse_tag('path', [ $file ], sub {
				      my ($p) = @_;
				      $state->{conflicts}{$p->fullname}{$pkg->id} = undef;
				      #- all these packages should be removed.
				      push @{$state->{ask_remove}{$p->fullname}}, { conflicts => $file, pkg => $pkg };
				  });
	    } elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
		$db->traverse_tag('whatprovides', [ $name ], sub {
				      my ($p) = @_;
				      if (grep { ranges_overlap($_, $property) } $p->provides) {
					  #- the existing package will conflicts with selection, check if a newer
					  #- version will be ok, else ask to remove the old.
					  my $packages = $urpm->find_candidate_packages($p->name);
					  my $best;
					  foreach (@{$packages->{$p->name}}) {
					      unless (grep { ranges_overlap($_, $property) } $_->provides) {
						  if ($best && $best != $_) {
						      $_->compare_pkg($best) > 0 and $best = $_;
						  } else {
						      $best = $_;
						  }
					      }
					  }
					  if ($best) {
					      push @properties, $best->id;
					  } else {
					      #- no package have been found, we need to remove the package examined.
					      push @{$state->{ask_remove}{$p->fullname}}, { conflicts => $property, pkg => $pkg };
					  }
				      }
				  });
	    }
	    #- we need to check a selected package is not selected.
	    #- if true, it should be unselected.
	    if (my ($name) =~ /^([^\s\[]*)/) {
		foreach (keys %{$urpm->{provides}{$name} || {}}) {
		    my $p = $urpm->{depslist}[$_];
		    ($pkg->flag_requested || $pkg->flag_required) && $pkg->flag_upgrade and
		      $state->{ask_unselect}{$p->id}{$pkg->id};
		}
	    }
	}
    }

    #- obsoleted packages are no longer marked as being asked to be removed.
    delete @{$state->{ask_remove}}{keys %{$state->{obsoleted}}};
}

#- compute installed flags for all package in depslist.
sub compute_installed_flags {
    my ($urpm, $db) = @_;

    #- first pass check according existing package.
    $db->traverse(sub {
		      my ($p) = @_;
		      foreach (keys %{$urpm->{provides}{$p->name} || {}}) {
			  my $pkg = $urpm->{depslist}[$_];
			  $pkg->name eq $p->name or next;
			  #- compute only installed and upgrade flags.
			  $pkg->set_flag_installed($pkg->compare_pkg($p) <= 0);
			  $pkg->set_flag_upgrade(!$pkg->flag_installed);
		      }
		  });

    #- second pass allow not installed package to be seen as upgrade.
    foreach (@{$urpm->{depslist}}) {
	$_->flag_upgrade || $_->flag_installed and next;
	$_->set_flag_upgrade(1);
    }
}

#- select packages to upgrade, according to package already registered.
#- by default, only takes best package and its obsoleted and compute
#- all installed or upgrade flag.
sub resolve_packages_to_upgrade {
    my ($urpm, $db, $state, %options) = @_;
    my (%names, %skip, %obsoletes);

    #- build direct access to best package according to name.
    foreach (@{$urpm->{depslist}}) {
	if ($_->is_arch_compat) {
	    my $p = $names{$_->name};
	    if ($p) {
		if ($_->compare_pkg($p) > 0) {
		    $names{$_->name} = $_;
		}
	    } else {
		$names{$_->name} = $_;
	    }
	}
    }

    #- check consistency with obsoletes of eligible package.
    #- it is important not to select a package wich obsolete
    #- an old one.
    foreach my $pkg (values %names) {
	foreach ($pkg->obsoletes) {
	    if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*)\s*([^\s\]]*)/) {
		if ($names{$n} && (!$o || eval($names{$n}->compare($v) . $o . 0))) {
		    #- an existing best package is obsoleted by another one.
		    $skip{$n} = undef;
		}
		push @{$obsoletes{$n}}, $pkg;
	    }
	}
    }

    #- now we can examine all existing packages to find packages to upgrade.
    $db->traverse(sub {
		      my ($p) = @_;
		      #- first try with package using the same name.
		      #- this will avoid selecting all packages obsoleting an old one.
		      if (my $pkg = $names{$p->name}) {
			  if ($pkg->compare_pkg($p) <= 0) {
			      #- this means the package is already installed (or there
			      #- is a old version in depslist).
			      $pkg->set_flag_installed(1);
			      $pkg->set_flag_upgrade(0);
			  } else {
			      #- the depslist version is better than existing one.
			      $pkg->set_flag_installed(0);
			      $pkg->set_flag_upgrade(1);
			      $state->{requested}{$pkg->id} = $options{requested};
			      return;
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
				      next if $pkg->name eq $p->name;
				      foreach ($pkg->obsoletes) {
					  if (ranges_overlap($property, $_)) {
					      #- the package being examined can be obsoleted.
					      #- do not set installed and provides flags.
					      $state->{requested}{$pkg->id} = $options{requested};
					      return;
					  }
				      }
				  }
			      }
			  }
		      }
		  });

    #TODO is conflicts for selection of package, it is important to choose
    #TODO right package to install.
}

1;
