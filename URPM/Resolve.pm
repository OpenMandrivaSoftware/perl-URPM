package URPM;

use strict;

#- find candidates packages from a require string (or id),
#- take care of direct choices using | sepatator.
sub find_candidate_packages {
    my ($urpm, $dep, %options) = @_;
    my %packages;

    foreach (split '\|', $dep) {
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
		!$urpm->{provides}{$name}{$_} || $pkg->provides_overlap($property, $options{nopromoteepoch}) and
		  push @{$packages{$pkg->name}}, $pkg;
	    }
	}
    }
    \%packages;
}

sub find_chosen_packages {
    my ($urpm, $db, $state, $dep) = @_;
    my %packages;

    #- search for possible packages, try to be as fast as possible, backtrack can be longer.
    foreach (split /\|/, $dep) {
	if (/^\d+$/) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->arch eq 'src' || $pkg->is_arch_compat or next;
	    $pkg->flag_skip || $state->{rejected}{$pkg->fullname} and next;
	    #- determine if this package is better than a possibly previously chosen package.
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
		$pkg->is_arch_compat or next;
		$pkg->flag_skip || exists $state->{rejected}{$pkg->fullname} and next;
		#- check if at least one provide of the package overlap the property (if sense are needed).
		if (!$urpm->{provides}{$name}{$_} || $pkg->provides_overlap($property)) {
		    #- determine if this package is better than a possibly previously chosen package.
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

	#- packages should be preferred if one of their provides is referenced
	#- in the "requested" hash, or if the package itself is requested (or
	#- required).
	#- If there is no preference, choose the first one by default (higher
	#- probability of being chosen) and ask the user.
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

	#- if several packages are installed, trim the choices.
	if (!$urpm->{options}{morechoices} && $mode == 3 && @chosen > 1) { @chosen = ($chosen[0]) }

	#- packages that require locales-xxx when the corresponding locales are
	#- already installed should be preferred over packages that require locales
	#- which are not installed.
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

	#- sort packages in order to have preferred ones first
	#- (this means good locales, no locales, bad locales).
	return (sort { $a->id <=> $b->id } @chosen_good_locales),
	       (sort { $a->id <=> $b->id } @chosen_other),
	       (sort { $a->id <=> $b->id } @chosen_bad_locales);
    }

    return values(%packages);
}

#- return unresolved requires of a package (a new one or a existing one).
sub unsatisfied_requires {
    my ($urpm, $db, $state, $pkg, %options) = @_;
    my %properties;

    #- all requires should be satisfied according to selected packages or installed packages,
    #- or the package itself.
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
		my $p = $urpm->{depslist}[$_];
		exists $state->{selected}{$_} or next;
		!$urpm->{provides}{$n}{$_} || $p->provides_overlap($dep, $options{nopromoteepoch}) and next REQUIRES;
	    }

	    #- check if the package itself provides what is necessary.
	    $pkg->provides_overlap($dep) and next REQUIRES;

	    #- check on installed system a package which is not obsoleted is satisfying the require.
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
	    $db->traverse_tag('whatrequires', [ $dep->{promote} ], sub {
				  my ($p) = @_;
				  if (my @l = $urpm->unsatisfied_requires($db, $state, $p,
									  nopromoteepoch => 1, name => $dep->{promote})) {
				      #- typically a redo of the diff_provides code should be applied...
				      $urpm->resolve_rejected($db, $state, $p,
							      removed => 1,
							      unsatisfied => \@properties,
							      from => scalar $dep->{psel}->fullname,
							      why => { unsatisfied => \@l });
				  }
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
		    $db->traverse_tag('whatrequires', [ $n ], sub {
					  my ($p) = @_;
					  if (my @l = $urpm->unsatisfied_requires($db, $state, $p, name => $n)) {
					      my $rv = $state->{rejected}{$p->fullname} ||= {};

					      #- keep track of what cause closure.
					      my %d; @d{@{$rv->{closure}{$pkg->fullname}{unsatisfied} ||= []}} = ();
					      push @{$rv->{closure}{$pkg->fullname}{unsatisfied}}, grep { ! exists $d{$_} } @l;

					      #- set removed and obsoleted level.
					      foreach (qw(removed obsoleted)) {
						  $options{$_} && (! exists $rv->{$_} || $options{$_} <= $rv->{$_}) and
						    $rv->{$_} = $options{$_};
					      }

					      #- continue the closure unless already examined.
					      exists $rv->{size} and return;
					      $rv->{size} = $p->size;

					      $p->pack_header; #- need to pack else package is no more visible...
					      push @closure, $p;
					  }
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
#-     between several possible packages.
#-   keep_requested_flag :
#-   keep_unrequested_dependencies :
#-   keep :
sub resolve_requested {
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
		unshift @properties, $urpm->backtrack_selected($db, $state, $dep, %options);
		next; #- backtrack code choose to continue with same package or completely new strategy.
	    } elsif ($options{callback_choices} && @chosen > 1) {
		unshift @properties, map {
		    +{
			required => $_->id,
			choices => $dep->{required},
			exists $dep->{from} ? (from => $dep->{from}) : @{[]},
			exists $dep->{requested} ? (requested => $dep->{requested}) : @{[]},
		    }
		} grep { ref $_ } $options{callback_choices}->($urpm, $db, $state, \@chosen);
		next; #- always redo according to choices.
	    }

	    #- now do the real work, select the package.
	    my ($pkg) = @chosen;
	    #- cancel flag if this package should be cancelled but too late (typically keep options).
	    my @keep;

	    !$pkg || exists $state->{selected}{$pkg->id} and next;

	    if ($pkg->arch eq 'src') {
		$pkg->set_flag_upgrade;
	    } else {
		unless ($pkg->flag_upgrade || $pkg->flag_installed) {
		    #- assume for this small algorithm package to be upgradable.
		    $pkg->set_flag_upgrade;
		    $db->traverse_tag('name', [ $pkg->name ], sub {
					  my ($p) = @_;
					  #- there is at least one package installed (whatever its version).
					  $pkg->set_flag_installed;
					  $pkg->flag_upgrade and $pkg->set_flag_upgrade($pkg->compare_pkg($p) > 0);
				      });
		}
		if ($pkg->flag_installed && !$pkg->flag_upgrade) {
		    my $allow;
		    #- the same or a more recent package is installed,
		    $db->traverse_tag('name', [ $pkg->name ], sub {
					  my ($p) = @_;
					  $allow ||= $pkg->compare_pkg($p) < 0;
				      });
		    #- if nothing has been found, just ignore it.
		    $allow or next;
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

	    #- check if package is not already installed before trying to use it, compute
	    #- obsoleted package too. this is valable only for non source package.
	    if ($pkg->arch ne 'src' && !$pkg->flag_disable_obsolete) {
		my (%diff_provides);

		foreach ($pkg->name." < ".$pkg->epoch.":".$pkg->version."-".$pkg->release, $pkg->obsoletes) {
		    $pkg->name eq $_ and next; #- this package obsoletes itself ?? Ignore.
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
			#- examine rpm db too (but only according to packages name as a fix in rpm itself)
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
				    if ($comparison > 0) {
					#- installed package is newer
					#- remove this package from the list of packages to install,
					#- unless urpmi was invoked with --allow-force (in which
					#- case rpm could be invoked with --oldpackage)
					if (!$urpm->{options}{'allow-force'}) {
					    $urpm->disable_selected($db, $state, $pkg);
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
	    unshift @properties, map { +{ required => $_, from => $pkg,
					  exists $dep->{promote} ? (promote => $dep->{promote}) : @{[]},
					  exists $dep->{psel} ? (psel => $dep->{psel}) : @{[]},
					} } $urpm->unsatisfied_requires($db, $state, $pkg);

	    #- keep in mind what is requiring each item (for unselect to work).
	    foreach ($pkg->requires_nosense) {
		$state->{whatrequires}{$_}{$pkg->id} = undef;
	    }

	    #- examine conflicts, an existing package conflicting with this selection should
	    #- be upgraded to a new version which will be safe, else it should be removed.
	    foreach ($pkg->conflicts) {
		@keep and last;
		#- propagate conflicts to avoided.
		if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\s*\[?([^\s\]]*)\s*([^\s\]]*)/) {
		    foreach (keys %{$urpm->{provides}{$n} || {}}) {
			my $p = $urpm->{depslist}[$_];
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
					      #- all these packages should be removed.
					      $urpm->resolve_rejected($db, $state, $p,
								      removed => 1, unsatisfied => \@properties,
								      from => scalar $pkg->fullname,
								      why => { conflicts => $file });
					  }
				      });
		} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
		    $db->traverse_tag('whatprovides', [ $name ], sub {
					  @keep and return;
					  my ($p) = @_;
					  if ($p->provides_overlap($property)) {
					      #- the existing package will conflicts with selection, check if a newer
					      #- version will be ok, else ask to remove the old.
					      my $need_deps = $p->name . " > " . ($p->epoch ? $p->epoch.":" : "") .
						$p->version . "-" . $p->release;
					      my $packages = $urpm->find_candidate_packages($need_deps, avoided => $state->{rejected});
					      my $best = join '|', map { $_->id }
						grep { ! $_->provides_overlap($property) }
						  @{$packages->{$p->name}};

					      if (length $best) {
						  unshift @properties, { required => $best, promote_conflicts => $name,  };
					      } else {
						  if ($options{keep}) {
						      push @keep, scalar $p->fullname;
						  } else {
						      #- no package have been found, we need to remove the package examined.
						      $urpm->resolve_rejected($db, $state, $p,
									      removed => 1, unsatisfied => \@properties,
									      from => scalar $pkg->fullname,
									      why => { conflicts => scalar $pkg->fullname });
						  }
					      }
					  }
				      });
		}
	    }

	    #- examine if an existing package does not conflicts with this one.
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
	    $db->traverse_tag('whatrequires', [ $n ], sub {
				  my ($p) = @_;
				  if (my @l = $urpm->unsatisfied_requires($db, $state, $p, nopromoteepoch => 1, name => $n)) {
				      #- try if upgrading the package will be satisfying all the requires...
				      #- there is no need to avoid promoting epoch as the package examined is not
				      #- already installed.
				      my $packages = $urpm->find_candidate_packages($p->name, avoided => $state->{rejected});
				      my $best = join '|', map { $_->id }
					grep { ($_->name eq $p->name ||
						$_->obsoletes_overlap($p->name." == ".$p->epoch.":".$p->version."-".$p->release))
						 && $_->fullname ne $p->fullname &&
						   $urpm->unsatisfied_requires($db, $state, $_, name => $n) == 0 }
					  map { @{$_ || []} } values %$packages;

				      if (length $best) {
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
				  }
			      });
	}
    } while (@diff_provides || @properties);

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
	exists $state->{selected}{$pkg->id} or next;

	#- keep a trace of what is deselected.
	push @unselected, $pkg;

	#- do a closure on rejected packages (removed, obsoleted or avoided).
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

	#- determine package that requires properties no more available, so that they need to be
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
    if (ref $val eq 'HASH') { $val = [ keys %$val ] }; #- compatibility with urpmi <= 4.5-13mdk
    my @regex;

    #- unless a regular expression is given, search in provides
    foreach my $name (@$val) {
	if ($name =~ m,^/(.*)/$,) {
	    push @regex, $1;
	} else {
	    foreach (keys %{$urpm->{provides}{$name} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
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
	    !$p || $pkg->compare_pkg($p) > 0 and $names{$pkg->name} = $pkg;
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
			  unless ($p->obsoletes_overlap($property)) {
			      if (my ($n) = $property =~ /^([^\s\[]*)/) {
				  foreach my $pkg (@{$obsoletes{$n} || []}) {
				      next if $pkg->name eq $p->name || $p->name ne $n || !$names{$pkg->name};
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

#- detect a dependency relation.
sub has_dependence {
    my ($urpm, $state, $a, $b) = @_;
    my %examined; $examined{$a} = undef;
    my @closure = $urpm->{depslist}[$a];

    while (my $pkg = shift @closure) {
	$pkg->id eq $b and return 1;
	if (my $from = $state->{selected}{$pkg->id}{from}) {
	    unless (exists $examined{$from->id}) {
		$examined{$from->id} = undef;
		push @closure, $from;
	    }
	}
	foreach ($pkg->provides_nosense) {
	    foreach (keys %{$state->{whatrequires}{$_} || {}}) {
		my $p = $urpm->{depslist}[$_] or next;
		$state->{selected}{$p->id} or next;
		exists $examined{$p->id} and next;
		$examined{$p->id} = undef;
		push @closure, $p;
	    }
	}
    }

    return 0;
}

#- build transaction set for given selection already done.
sub build_transaction_set {
    my ($urpm, $db, $state, %options) = @_;

    #- clean transaction set.
    $state->{transaction} = [];

    if ($options{split_length}) {
	#- first step consists of sorting packages according to dependencies.
	my @sorted = sort { ($a <=> $b, -1, 1, 0)[($urpm->has_dependence($state, $a, $b) && 1) +
						  ($urpm->has_dependence($state, $b, $a) && 2)] }
	  grep { (! defined $options{start} || $_ >= $options{start}) &&
		   (! defined $options{end} || $_ <= $options{end}) } keys %{$state->{selected}};

	#- second step consists of re-applying resolve_requested in the same
	#- order computed in first step and to update a list of package to
	#- install, to upgrade and to remove.
	my (%requested, %examined);
	foreach (@sorted) {
	    $requested{$_} = undef;
	    if (keys(%requested) >= $options{split_length}) {
		my %set;

		$urpm->resolve_requested($db, $state->{transaction_state} ||= {}, \%requested,
					 keep_requested_flag => 1,
					 defined $options{start} ? (start => $options{start}) : @{[]},
					 defined $options{end}   ? (end   => $options{end}) : @{[]});
		%requested = ();

		foreach (keys %{$state->{transaction_state}{selected}}) {
		    exists $examined{$_} and next;
		    $examined{$_} = undef;
		    push @{$set{upgrade}}, $_;
		}
		foreach (keys %{$state->{transaction_state}{rejected}}) {
		    exists $examined{$_} and next;
		    $examined{$_} = undef;
		    $state->{transaction_state}{rejected}{$_}{removed} &&
		      !$state->{transaction_state}{rejected}{$_}{obsoleted} or next;
		    push @{$set{remove}}, $_;
		}
		%set and push @{$state->{transaction}}, \%set;
	    }
	}

	#- check transaction set has been correctly created,
	#- possible error are other package removed which should not be the case.
	if (keys(%{$state->{selected}}) == keys(%{$state->{transaction_state}{selected}}) &&
	    (grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}}) ==
	    (grep { $state->{transaction_state}{rejected}{$_}{removed} && !$state->{transaction_state}{rejected}{$_}{obsoleted} }
	     keys %{$state->{transaction_state}{rejected}})
	   ) {
	    foreach (keys(%{$state->{selected}})) {
		exists $state->{transaction_state}{selected}{$_} and next;
		$state->{transaction} = []; last;
	    }
	    foreach (grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}}) {
		$state->{transaction_state}{rejected}{$_}{removed} &&
		  !$state->{transaction_state}{rejected}{$_}{obsoleted} and next;
		$state->{transaction} = []; last;
	    }
	}
    }

    #- fallback if something can be selected but nothing has been allowed in transaction list.
    if (%{$state->{selected} || {}} && !@{$state->{transaction}}) {
	push @{$state->{transaction}}, {
					upgrade => [ keys %{$state->{selected}} ],
					remove  => [ grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} }
						     keys %{$state->{rejected}} ],
				       };
    }

    $state->{transaction};
}

#- compatiblity method which are going to be removed.
sub resolve_closure_ask_remove {
    my ($urpm, $db, $state, $pkg, $from, $why) = @_;

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
    my ($urpm, $db, $state, $unrequested, %_options) = @_;

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
