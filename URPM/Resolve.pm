package URPM;

use strict;

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
    @requested{map { split '\|', $_ } @properties} = ();
    while (defined ($dep = shift @properties)) {
	my ($allow_src, %packages, @chosen_requested, @chosen_upgrade, @chosen, %diff_provides, $pkg);
	foreach (split '\|', $dep) {
	    if (/^\d+$/) {
		my $pkg = $urpm->{depslist}[$_];
		$allow_src = 1;
		push @{$packages{$pkg->name}}, $pkg;
	    } elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
		foreach (keys %{$urpm->{provides}{$name} || {}}) {
		    my $pkg = $urpm->{depslist}[$_];
		    my $satisfied = 0;
		    #- check if at least one provide of the package overlap the property.
		    foreach ($pkg->provides) {
			ranges_overlap($property, $_) and ++$satisfied, last;
		    }
		    $satisfied and push @{$packages{$pkg->name}}, $pkg;
		}
	    }
	}
	#- take the best package for each choices of same name.
	foreach (values %packages) {
	    my $best;
	    foreach (@$_) {
		if (defined $allow_src && $_->arch eq 'src' || $_->is_arch_compat) {
		    if ($best && $best != $_) {
			$_->compare_pkg($best) > 0 and $best = $_;
		    } else {
			$best = $_;
		    }
		}
	    }
	    $_ = $best;
	}
	if (keys %packages > 1) {
	    #- package should be prefered if one of their provides is referenced
	    #- in requested hash or package itself is requested (or required).
	    #- if there is no preference choose the first one (higher probability
	    #- of being chosen) by default and ask user.
	    foreach my $pkg (values %packages) {
		$pkg or next; #- this could happen if no package are suitable for this arch.
		if (exists $requested{$pkg->id}) {
		    push @chosen_requested, $pkg;
		} elsif ($db->traverse_tag('name', [ $pkg->name ], undef) > 0) {
		    push @chosen_upgrade, $pkg;
		} else {
		    push @chosen, $pkg;
		}
	    }
	    @chosen_requested > 0 and @chosen = @chosen_requested;
	    @chosen_requested == 0 and @chosen_upgrade > 0 and @chosen = @chosen_upgrade;
	} else {
	    @chosen = values %packages;
	}
	if (@chosen > 1) {
	    #- solve choices by asking user.
	    print STDERR "asking user for ".scalar(@chosen)." choices\n";
	    #TODO
	}
	$pkg ||= $chosen[0];
	$pkg && !$pkg->flag_requested && !$pkg->flag_required or next;

	#- keep in mind the package has be selected.
	$pkg->set_flag_requested(exists $requested{$dep});
	$pkg->set_flag_required(! exists $requested{$dep});

	#- check if package is not already installed before trying to use it, compute
	#- obsoleted package too. this is valable only for non source package.
	if ($pkg->arch ne 'src') {
	    $pkg->flag_installed and next;
	    unless ($pkg->flag_upgrade) {
		$db->traverse_tag('name', [ $pkg->name ], sub {
				      my ($p) = @_;
				      $pkg->flag_installed or
					$pkg->set_flag_installed($pkg->compare_pkg($p) <= 0);
				  });
		$pkg->set_flag_upgrade(!$pkg->flag_installed);
	    }
	    $pkg->flag_installed and next;

	    #- keep in mind the provides of this package, so that future requires can be satisfied
	    #- with this package potentially.
	    foreach ($pkg->provides) {
		$state->{provided}{$_}{$pkg->id} = undef;
	    }

	    foreach ($pkg->name, $pkg->obsoletes) {
		if (my ($n, $o, $v) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*)\s*([^\s\]]*)/) {
		    $db->traverse_tag('name', [ $n ], sub {
					  my ($p) = @_;
					  eval($p->compare($v) . $o . 0) or return;

					  $state->{obsoleted}{$p->fullname}{$pkg->id} = undef;

					  foreach ($p->provides) {
					      #- check if a installed property has been required which needs to be
					      #- re-evaluated to solve this one.
					      if (my $ip = $state->{installed}{$_}) {
						  if (exists $ip->{$p->fullname} && keys(%$ip) == 1) {
						      push @properties, $n;
						      delete $state->{installed}{$_};
						  } else {
						      delete $ip->{$p->fullname};
						  }
					      }
					      #- check differential provides between obsoleted package and newer one.
					      $state->{provided}{$_} or $diff_provides{$n} = undef;
					  }
				      });
		}
	    }

	    foreach my $n (keys %diff_provides) {
		$db->traverse_tag('whatrequires', [ $n ], sub {
				      my ($p) = @_;
				      my ($needed, $satisfied) = (0, 0);
				      foreach ($p->requires) {
					  if (my ($pn, $o, $v) = /^([^\[]*)(?:\[\*\])?\[?([^\s\]]*)\s*([^\s\]]*)/) {
					      if ($o) {
						  $pn eq $n && $pn eq $pkg->name or next;
						  ++$needed;
						  eval($pkg->compare($v) . $o . 0) or next;
						  #- an existing provides (propably the one examined) is satisfying.
						  ++$satisfied;
					      } else {
						  $pn eq $n && $pn ne $pkg->name or next;
						  #- a property has been removed since in diff_provides.
						  ++$needed;
					      }
					  }
				      }
				      #- check if the package need to be updated because it
				      #- losts some of its requires regarding the current diff_provides.
				      if ($needed > $satisfied) {
					  push @properties, $p->name;
				      }
				  });
	    }
	}

	#- all requires should be satisfied according to selected package, or installed packages.
	foreach ($pkg->requires) {
	    $state->{provided}{$_} || $state->{installed}{$_} and next;
	    #- keep track if satisfied.
	    my $satisfied = 0;
	    #- check on selected package if a provide is satisfying the resolution (need to do the ops).
	    foreach my $provide (keys %{$state->{provided}}) {
		ranges_overlap($provide, $_) and ++$satisfied, last;
	    }
	    #- check on installed system a package which is not obsoleted is satisfying the require.
	    unless ($satisfied) {
		if (my ($file) = /^(\/[^\s\[]*)/) {
		    $db->traverse_tag('path', [ $file ], sub {
			my ($p) = @_;
			exists $state->{obsoleted}{$p->fullname} and return;
			++$satisfied;
		    });
		} elsif (my ($property, $name) = /^(([^\s\[]*).*)/) {
		    $db->traverse_tag('whatprovides', [ $name ], sub {
					  my ($p) = @_;
					  exists $state->{obsoleted}{$p->fullname} and return;
					  foreach ($p->provides) {
					      $state->{installed}{$_}{$p->fullname} = undef;
					      ranges_overlap($_, $property) and ++$satisfied, return;
					  }
				      });
		}
	    }
	    #- if nothing can be done, the require should be resolved.
	    $satisfied or push @properties, $_;
	}

	#- examine conflicts.
	#TODO
    }
}

1;
