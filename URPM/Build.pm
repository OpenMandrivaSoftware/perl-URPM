package URPM;

use strict;

#- prepare build of an hdlist from a list of files.
#- it can be used to start computing depslist.
sub parse_rpms_build_headers {
    my ($urpm, $dir, @rpms) = @_;
    my (%cache, @headers, %names);

    #- build a working directory which will hold rpm headers.
    $dir ||= '.';
    -d $dir or mkdir $dir, 0755 or die "cannot create directory $dir\n";

    #- examine cache if it contains any headers which will be much faster to read
    #- than parsing rpm file directly.
    local *DIR;
    opendir DIR, $dir;
    while (my $file = readdir DIR) {
	$file =~ /(.+?-[^:\-]+-[^:\-]+\.[^:\-\.]+)(?::(\S+))?$/ or next;
	$cache{$2 || $1} = $file;
    }
    closedir DIR;

    foreach (@rpms) {
	my ($key) = /([^\/]*)\.rpm$/ or next; #- get rpm filename.
	my ($id, $filename);

	if ($cache{$key} && -s "$dir/$cache{$key}") {
	    ($id, undef) = $urpm->parse_hdlist("$dir/$cache{$key}", 1);
	    defined $id or die "bad header $dir/$cache{$key}\n";

	    $filename = $cache{$key};
	} else {
	    ($id, undef) = $urpm->parse_rpm($_);
	    defined $id or die "bad rpm $_\n";
	
	    my $pkg = $urpm->{depslist}[$id];

	    $filename = $pkg->fullname;
	    "$filename.rpm" eq $pkg->filename or $filename .= ":$key";

	    print STDERR "$dir/$filename\n";
	    unless (-s "$dir/$filename") {
		local *F;
		open F, ">$dir/$filename";
		$pkg->build_header(fileno *F);
		close F;
	    }
	    -s "$dir/$filename" or unlink("$dir/$filename"), die "can create header $dir/$filename\n";

	    #- make smart use of memory (no need to keep header in memory now).
	    $pkg->pack_header;
	}

	#- keep track of header associated (to avoid rereading rpm filename directly
	#- if rereading has been made neccessary).
	push @headers, $filename;
    }
    @headers;
}

#- check if rereading of hdlist is neccessary.
sub unresolved_provides_clean {
    my ($urpm) = @_;
    my @unresolved = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};

    #- names can be safely removed in any cases.
    delete $urpm->{names};

    #- remove
    @{$urpm}{qw(depslist provides)} = ([], {});
    @{$urpm->{provides}}{@unresolved} = ();

    @unresolved;
}

#- read a list of headers (typically when building an hdlist when provides have
#- been cleaned.
sub parse_headers {
    my ($urpm, $dir, @headers) = @_;
    my ($start, $id);

    $dir ||= '.';
    -d $dir or die "no directory $dir\n";

    $start = @{$urpm->{depslist} || []};
    foreach (@headers) {
	#- make smart use of memory (no need to keep header in memory now).
	($id, undef) = $urpm->parse_hdlist("$dir/$_", 1);
	defined $id or die "bad header $dir/$_\n";
    }
    defined $id ? ($start, $id) : ();
}

#- compute dependencies, result in stored in info values of urpm.
#- operations are incremental, it is possible to read just one hdlist, compute
#- dependencies and read another hdlist, and again.
sub compute_deps {
    my ($urpm) = @_;

    #- avoid recomputing already present infos, take care not to modify
    #- existing entries, as the array here is used instead of values of infos.
    my $start = @{$urpm->{deps} ||= []};
    my $end = $#{$urpm->{depslist} || []};

    #- check if something has to be done.
    $start > $end and return;

    #- take into account in which hdlist a package has been found.
    #- this can be done by an incremental take into account generation
    #- of depslist.ordered part corresponding to the hdlist.
    #- compute closed requires, do not take into account choices.
    foreach ($start .. $end) {
	my $pkg = $urpm->{depslist}[$_];

	my %required_packages;
	my @required_packages;
	my %requires; @requires{$pkg->requires_nosense} = ();
	my @requires = keys %requires;

	while (my $req = shift @requires) {
	    $req =~ /^basesystem/ and next; #- never need to requires basesystem directly as always required! what a speed up!
	    $req = ($req =~ /^[0-9]+$/ && [ $req ] ||
		    $urpm->{provides}{$req} && [ keys %{$urpm->{provides}{$req}} ] ||
		    [ ($req !~ /NOTFOUND_/ && "NOTFOUND_") . $req ]);
	    if (@$req > 1) {
		#- this is a choice, no closure need to be done here.
		push @required_packages, $req;
	    } else {
		#- this could be nothing if the provides is a file not found.
		#- and this has been fixed above.
		foreach (@$req) {
		    my $pkg_ = /^[0-9]+$/ && $urpm->{depslist}[$_];
		    exists $required_packages{$_} and next;
		    $required_packages{$_} = undef; $pkg_ or next;
		    foreach ($pkg_->requires_nosense) {
			unless (exists $requires{$_}) {
			    $requires{$_} = undef;
			    push @requires, $_;
			}
		    }
		}
	    }
	}
	#- examine choice to remove those which are not mandatory.
	foreach (@required_packages) {
	    unless (grep { exists $required_packages{$_} } @$_) {
		$required_packages{join '|', sort { $a <=> $b } @$_} = undef;
	    }
	}

	#- store a short representation of requires.
	$urpm->{requires}[$_] = join ' ', keys %required_packages;
    }

    #- expand choices and closure again.
    my %ordered;
    foreach ($start .. $end) {
	my %requires;
	my @requires = ($_);
	while (my $dep = shift @requires) {
	    exists $requires{$dep} || /^[^0-9\|]*$/ and next;
	    foreach ($dep, split ' ', $urpm->{requires}[$dep]) {
		if (/\|/) {
		    push @requires, split /\|/, $_;
		} else {
		    /^[0-9]+$/ and $requires{$_} = undef;
		}
	    }
	}

	my $pkg = $urpm->{depslist}[$_];
	my $delta = 1 + ($pkg->name eq 'basesystem' ? 10000 : 0) + ($pkg->name eq 'msec' ? 20000 : 0);
	foreach (keys %requires) {
	    $ordered{$_} += $delta;
	}
    }

    #- some package should be sorted at the beginning.
    my $fixed_weight = 10000;
    foreach (qw(basesystem msec * locales filesystem setup glibc sash bash libtermcap2 termcap readline ldconfig)) {
	foreach (keys %{$urpm->{provides}{$_} || {}}) {
	    /^[0-9]+$/ and $ordered{$_} = $fixed_weight;
	}
	$fixed_weight += 10000;
    }
    foreach ($start .. $end) {
	my $pkg = $urpm->{depslist}[$_];

	$pkg->name =~ /locales-[a-zA-Z]/ and $ordered{$_} = 35000;
    }

    #- compute base flag, consists of packages which are required without
    #- choices of basesystem and are ALWAYS installed. these packages can
    #- safely be removed from requires of others packages.
    foreach (qw(basesystem glibc kernel)) {
	foreach (keys %{$urpm->{provides}{$_} || {}}) {
	    foreach ($_, split ' ', $urpm->{requires}[$_]) {
		/^[0-9]+$/ and $urpm->{depslist}[$_] and $urpm->{depslist}[$_]->set_flag_base(1);
	    }
	}
    }

    #- give an id to each packages, start from number of package already
    #- registered in depslist.
    my %remap_ids; @remap_ids{sort {
	$ordered{$b} <=> $ordered{$a} or do {
	    my ($na, $nb) = map { $urpm->{depslist}[$_]->name } ($a, $b);
	    my ($sa, $sb) = map { /^lib(.*)/ and $1 } ($na, $nb);
	    $sa && $sb ? $sa cmp $sb : $sa ? -1 : $sb ? +1 : $na cmp $nb;
	}} ($start .. $end)} = ($start .. $end);

    #- recompute requires to use packages id, drop any base packages or
    #- reference of a package to itself.
    my @depslist;
    foreach ($start .. $end) {
	my $pkg = $urpm->{depslist}[$_];

	#- set new id.
	$pkg->set_id($remap_ids{$_});

	my ($id, $base, %requires_id);
	foreach (split ' ', $urpm->{requires}[$_]) {
	    if (/\|/) {
		#- all choices are grouped together at the end of requires,
		#- this allow computation of dropable choices.
		my ($to_drop, @choices_base_id, @choices_id);
		foreach (split /\|/, $_) {
		    my ($id, $base) = /^[0-9]+$/ ? (exists $remap_ids{$_} ? $remap_ids{$_} : $_,
						    $urpm->{depslist}[$_]->flag_base) : ($_, 0);
		    $base and push @choices_base_id, $id;
		    $base &&= ! $pkg->flag_base;
		    $to_drop ||= $id == $pkg->id || exists $requires_id{$id} || $base;
		    push @choices_id, $id;
		}

		#- package can safely be dropped as it will be selected in requires directly.
		$to_drop and next;

		#- if a base package is in a list, keep it instead of the choice.
		if (@choices_base_id) {
		    @choices_id = @choices_base_id;
		    $base = 1;
		}
		if (@choices_id == 1) {
		    $id = $choices_id[0];
		} else {
		    my $choices_key = join '|', sort { $a <=> $b } @choices_id;
		    $requires_id{$choices_key} = undef;
		    next;
		}
	    } else {
		($id, $base) = /^[0-9]+$/ ? (exists $remap_ids{$_} ? $remap_ids{$_} : $_,
					     $urpm->{depslist}[$_]->flag_base) : ($_, 0);
	    }

	    #- select individual package.
	    $base &&= ! $pkg->flag_base;
	    $id == $pkg->id || $base or $requires_id{$id} = undef;
	}
	#- be smart with memory usage.
	delete $urpm->{requires}[$_];
	$urpm->{deps}[$remap_ids{$_}] = join(' ', sort { $a <=> $b } map { join '|', sort { $a <=> $b } @{ref $_ ? $_ : [$_]} } keys %requires_id);
	$depslist[$remap_ids{$_}-$start] = $pkg;
    }

    #- remap all provides ids for new package position and update depslist.
    @{$urpm->{depslist}}[$start .. $end] = @depslist;
    foreach my $h (values %{$urpm->{provides}}) {
	my %provided;
	foreach (keys %{$h || {}}) {
	    $provided{exists $remap_ids{$_} ? $remap_ids{$_} : $_} = delete $h->{$_};
	}
	$h = \%provided;
    }
    delete $urpm->{requires};

    ($start, $end);
}

#- build an hdlist from existing depslist, from start to end inclusive.
sub build_hdlist {
    my ($urpm, $start, $end, $dir, $hdlist, $ratio, $split_ratio) = @_;

    #- compression ratio are not very high, sample for cooker
    #- gives the following (main only and cache fed up):
    #- ratio compression_time  size
    #-   9       21.5 sec     8.10Mb   -> good for installation CD
    #-   6       10.7 sec     8.15Mb
    #-   5        9.5 sec     8.20Mb
    #-   4        8.6 sec     8.30Mb   -> good for urpmi
    #-   3        7.6 sec     8.60Mb
    $ratio ||= 4;
    $split_ratio ||= 400000;

    open B, "| $ENV{LD_LOADER} packdrake -b${ratio}ds '$hdlist' '$dir' $split_ratio";
    foreach (@{$urpm->{depslist}}[$start .. $end]) {
	my $filename = $_->fullname;
	"$filename.rpm" ne $_->filename && $_->filename =~ /([^\/]*)\.rpm$/ and $filename .= ":$1";
	-s "$dir/$filename" or die "bad header $dir/$filename\n";
	print B "$filename\n";
    }
    close B or die "packdrake failed\n";
}

#- build synthesis file.
sub build_synthesis {
    my ($urpm, $start, $end, $synthesis) = @_;

    $start > $end and return;

    #- first pass: traverse provides to find files provided.
    my %provided_files;
    foreach (keys %{$urpm->{provides}}) {
	/^\// or next;
	foreach my $id (keys %{$urpm->{provides}{$_} || {}}) {
	    push @{$provided_files{$id} ||= []}, $_;
	}
    }

    local *F;
    open F, "| $ENV{LD_LOADER} gzip -9 >'$synthesis'";
    foreach ($start .. $end) {
	my $pkg = $urpm->{depslist}[$_];
	my %files;

	if ($provided_files{$_}) {
	    @files{@{$provided_files{$_}}} = undef;
	    delete @files{$pkg->provides_nosense};
	}

	$pkg->build_info(fileno *F, join('@', keys %files));
    }
    close F;
}

#- write depslist.ordered file according to info in params.
sub build_base_files {
    my ($urpm, $depslist, $provides, $compss) = @_;
    local *F;

    if ($depslist) {
	open F, ">$depslist";
	for (0 .. $#{$urpm->{depslist}}) {
	    my $pkg = $urpm->{depslist}[$_];

	    printf F ("%s-%s-%s.%s%s %s %s\n", $pkg->fullname,
		      ($pkg->epoch ? ':' . $pkg->epoch : ''), $pkg->size || 0, $urpm->{deps}[$_]);
	}
	close F;
    }

    if ($provides) {
	open F, ">$provides";
	while (my ($k, $v) = each %{$urpm->{provides}}) {
	    printf F "%s\n", join '@', $k, map { scalar $urpm->{depslist}[$_]->fullname } keys %{$v || {}};
	}
	close F;
    }

    if ($compss) {
	my %p;

	open F, ">$compss";
	foreach (@{$urpm->{depslist}}) {
	    $_->group or next;
	    push @{$p{$_->group} ||= []}, $_->name;
	}
	foreach (sort keys %p) {
	    print F $_, "\n";
	    foreach (@{$p{$_}}) {
		print F "\t", $_, "\n";
	    }
	    print F "\n";
	}
	close F;
    }

    1;
}

1;
