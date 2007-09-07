package URPM;

# $Id$

use strict;

sub _get_tmp_dir () {
    my $t = $ENV{TMPDIR};
    $t && -w $t or $t = '/tmp';
    "$t/.build_hdlist";
}

#- prepare build of an hdlist from a list of files.
#- it can be used to start computing depslist.
#- parameters are :
#-   rpms     : array of all rpm file name to parse (mandatory)
#-   dir      : directory which will contain headers (defaults to /tmp/.build_hdlist)
#-   callback : perl code to be called for each package read (defaults pack_header)
#-   clean    : bool to clean cache before (default no).
#-   packing  : bool to create info (default is weird)
sub parse_rpms_build_headers {
    my ($urpm, %options) = @_;
    my ($dir, %cache, @headers);

    #- check for mandatory options.
    if (@{$options{rpms} || []} > 0) {
	#- build a working directory which will hold rpm headers.
	$dir = $options{dir} || _get_tmp_dir();
	$options{clean} and system($ENV{LD_LOADER} ? $ENV{LD_LOADER} : @{[]}, "rm", "-rf", $dir);
	-d $dir or mkdir $dir, 0755 or die "cannot create directory $dir\n";

	#- examine cache if it contains any headers which will be much faster to read
	#- than parsing rpm file directly.
	unless ($options{clean}) {
	    my $dirh;
	    opendir $dirh, $dir;
	    while (defined (my $file = readdir $dirh)) {
		my ($fullname, $filename) = $file =~ /(.+?-[^:\-]+-[^:\-]+\.[^:\-\.]+)(?::(\S+))?$/ or next;
		my @stat = stat "$dir/$file";
		$cache{$filename || $fullname} = {
		    file => $file,
		    size => $stat[7],
		    'time' => $stat[9],
		};
	    }
	    closedir $dirh;
	}

	foreach (@{$options{rpms}}) {
	    my ($key) = m!([^/]*)\.rpm$! or next; #- get rpm filename.
	    my ($id, $filename);

	    if ($cache{$key} && $cache{$key}{time} > 0 && $cache{$key}{time} >= (stat $_)[9]) {
		($id, undef) = $urpm->parse_hdlist("$dir/$cache{$key}{file}", packing => $options{packing}, keep_all_tags => $options{keep_all_tags});
		unless (defined $id) {
		  if ($options{dontdie}) {
		    print STDERR "bad header $dir/$cache{$key}{file}\n";
		    next;
		  } else {
		    die "bad header $dir/$cache{$key}{file}\n";
		  }
		}

		$options{callback} and $options{callback}->($urpm, $id, %options, (file => $_));

		$filename = $cache{$key}{file};
	    } else {
		($id, undef) = $urpm->parse_rpm($_, keep_all_tags => $options{keep_all_tags});
		unless (defined $id) {
		    if ($options{dontdie}) {
			print STDERR "bad rpm $_\n";
			next;
		    } else {
			die "bad rpm $_\n";
		    }
		}
		
		my $pkg = $urpm->{depslist}[$id];

		$filename = $pkg->fullname;
		"$filename.rpm" eq $pkg->filename or $filename .= ":$key";

		unless (-s "$dir/$filename") {
		    open my $fh, ">$dir/$filename" or die "unable to open $dir/$filename for writing\n";
		    $pkg->build_header(fileno $fh);
		    close $fh;
		}
		-s "$dir/$filename" or unlink("$dir/$filename"), die "can create header $dir/$filename\n";

		#- make smart use of memory (no need to keep header in memory now).
		if ($options{callback}) {
		    $options{callback}->($urpm, $id, %options, (file => $_));
		} else {
			$pkg->pack_header;
		}

		# Olivier Thauvin <thauvin@aerov.jussieu.fr>
		# isn't this code better, but maybe it will break some tools:
		# $options{callback}->($urpm, $id, %options, (file => $_)) if ($options{callback});
		# $pkg->pack_header;
	    }

	    #- keep track of header associated (to avoid rereading rpm filename directly
	    #- if rereading has been made neccessary).
	    push @headers, $filename;
	}
    }
    @headers;
}

#- allow rereading of hdlist and clean.
sub unresolved_provides_clean {
    my ($urpm) = @_;
    $urpm->{depslist} = [];
    $urpm->{provides}{$_} = undef foreach keys %{$urpm->{provides} || {}};
}

#- read a list of headers (typically when building an hdlist when provides have
#- been cleaned).
#- parameters are :
#-   headers  : array containing all headers filenames to parse (mandatory)
#-   dir      : directory which contains headers (defaults to /tmp/.build_hdlist)
#-   callback : perl code to be called for each package read (defaults to pack_header)
sub parse_headers {
    my ($urpm, %options) = @_;
    my ($dir, $start, $id);

    $dir = $options{dir} || _get_tmp_dir();
    -d $dir or die "no directory $dir\n";

    $start = @{$urpm->{depslist} || []};
    foreach (@{$options{headers} || []}) {
	#- make smart use of memory (no need to keep header in memory now).
	($id, undef) = $urpm->parse_hdlist("$dir/$_", packing => !$options{callback});
	defined $id or die "bad header $dir/$_\n";
	$options{callback} and $options{callback}->($urpm, $id, %options);
    }
    defined $id ? ($start, $id) : @{[]};
}

# parse_rpms, same behaviour than parse_{hdlist, synthesis}
# ie: ($start, $end) = parse_*(filestoparse, %options);

sub parse_rpms {
    my ($urpm, $rpms, %options) = @_;
    my ($start, $end);
    $urpm->parse_rpms_build_headers(
        rpms => $rpms, 
        %options, 
        callback => sub {
            my (undef, $id) = @_;
	    $start = $id if $start > $id || ! defined($start);
	    $end = $id   if $end < $id   || ! defined($end);
        }
    ) ? ($start, $end) : ();
}

# fuzzy_parse is a simple wrapper for parse_rpm* function
# It detect if the file passed is a dir, an hdlist, a synthesis or a rpm
# it call the good function. 
sub fuzzy_parse {
    my ($urpm, %options) = @_;
    my ($start, $end);
    foreach my $entry (@{$options{paths} || []}) {
        if (-d $entry) { # it is a dir
	    ($start, $end) = $urpm->parse_rpms([ glob("$entry/*.rpm") ], %options);
	    defined ($start) and return ($start .. $end);
	} else { # we try some methode to load the file
	    ($start, $end) = $urpm->parse_hdlist($entry);
	    defined ($start) and return ($start .. $end);

	    ($start, $end) = $urpm->parse_synthesis($entry);
	    defined ($start) and return ($start .. $end);

	    ($start, $end) = $urpm->parse_rpms([ $entry ], %options);
	    defined ($start) and return ($start .. $end);
        }
    }
    return ();
}

#- build an hdlist from existing depslist, from start to end inclusive.
#- parameters are :
#-   hdlist   : hdlist file to use.
#-   dir      : directory which contains headers (defaults to /tmp/.build_hdlist)
#-   start    : index of first package (defaults to first index of depslist).
#-   end      : index of last package (defaults to last index of depslist).
#-   idlist   : id list of rpm to compute (defaults is start .. end)
#-   ratio    : compression ratio (default 4).
#-   split    : split ratio (default 400kb, see MDV::Packdrakeng).
sub build_hdlist {
    my ($urpm, %options) = @_;
    my ($dir, $ratio, @idlist);

    $dir = $options{dir} || _get_tmp_dir();
     -d $dir or die "no directory $dir\n";

    @idlist = $urpm->build_listid($options{start}, $options{end}, $options{idlist});

    #- compression ratio are not very high, sample for cooker
    #- gives the following (main only and cache fed up):
    #- ratio compression_time  size
    #-   9       21.5 sec     8.10Mb   -> good for installation CD
    #-   6       10.7 sec     8.15Mb
    #-   5        9.5 sec     8.20Mb
    #-   4        8.6 sec     8.30Mb   -> good for urpmi
    #-   3        7.6 sec     8.60Mb
    $ratio = $options{ratio} || 4;

    require MDV::Packdrakeng;
    my $pack = MDV::Packdrakeng->new(
	archive => $options{hdlist},
	compress => "gzip",
	uncompress => "gzip -d",
	block_size => $options{split},
	comp_level => $ratio,
    ) or die "Can't create archive";
    foreach my $pkg (@{$urpm->{depslist}}[@idlist]) {
	my $filename = $pkg->fullname;
	"$filename.rpm" ne $pkg->filename && $pkg->filename =~ m!([^/]*)\.rpm$!
	    and $filename .= ":$1";
	-s "$dir/$filename" or die "bad header $dir/$filename\n";
	$pack->add($dir, $filename);
    }
}

#- build synthesis file.
#- parameters are :
#-   synthesis : synthesis file to create (mandatory if fd not given).
#-   fd        : file descriptor (mandatory if synthesis not given).
#-   start     : index of first package (defaults to first index of depslist).
#-   end       : index of last package (defaults to last index of depslist).
#-   idlist    : id list of rpm to compute (defaults is start .. end)
#-   ratio     : compression ratio (default 9).
#- returns true on success
sub build_synthesis {
    my ($urpm, %options) = @_;
    my ($ratio, @idlist);

    @idlist = $urpm->build_listid($options{start}, $options{end}, $options{idlist});

    $ratio = $options{ratio} || 9;
    $options{synthesis} || defined $options{fd} or die "invalid parameters given";

    #- first pass: traverse provides to find files provided.
    my %provided_files;
    foreach (keys %{$urpm->{provides}}) {
	m!^/! or next;
	foreach my $id (keys %{$urpm->{provides}{$_} || {}}) {
	    push @{$provided_files{$id} ||= []}, $_;
	}
    }


    #- second pass: write each info including files provided.
    $options{synthesis} and open my $fh, "| " . ($ENV{LD_LOADER} || '') . " gzip -$ratio >'$options{synthesis}'";
    foreach (@idlist) {
	my $pkg = $urpm->{depslist}[$_];
	my %files;

	if ($provided_files{$_}) {
	    @files{@{$provided_files{$_}}} = undef;
	    delete @files{$pkg->provides_nosense};
	}

	$pkg->build_info($options{synthesis} ? fileno $fh : $options{fd}, join('@', keys %files));
    }
    close $fh; # returns true on success
}

#- write depslist.ordered file according to info in params.
#- parameters are :
#-   depslist : depslist.ordered file to create.
#-   provides : provides file to create.
#-   compss   : compss file to create.
sub build_base_files {
    my ($urpm, %options) = @_;

    if ($options{depslist}) {
	open my $fh, ">", $options{depslist} or die "Can't write to $options{depslist}: $!\n";
	foreach (0 .. $#{$urpm->{depslist}}) {
	    my $pkg = $urpm->{depslist}[$_];

	    printf $fh ("%s-%s-%s.%s%s %s %s\n", $pkg->fullname,
		      ($pkg->epoch ? ':' . $pkg->epoch : ''), $pkg->size || 0, $urpm->{deps}[$_]);
	}
	close $fh;
    }

    if ($options{provides}) {
	open my $fh, ">", $options{provides} or die "Can't write to $options{provides}: $!\n";
	while (my ($k, $v) = each %{$urpm->{provides}}) {
	    printf $fh "%s\n", join '@', $k, map { scalar $urpm->{depslist}[$_]->fullname } keys %{$v || {}};
	}
	close $fh;
    }

    if ($options{compss}) {
	my %p;

	open my $fh, ">", $options{compss} or die "Can't write to $options{compss}: $!\n";
	foreach (@{$urpm->{depslist}}) {
	    $_->group or next;
	    push @{$p{$_->group} ||= []}, $_->name;
	}
	foreach (sort keys %p) {
	    print $fh $_, "\n";
	    foreach (@{$p{$_}}) {
		print $fh "\t", $_, "\n";
	    }
	    print $fh "\n";
	}
	close $fh;
    }

    1;
}

our $MAKEDELTARPM = '/usr/bin/makedeltarpm';

#- make_delta_rpm($old_rpm_file, $new_rpm_file)
# Creates a delta rpm in the current directory.

sub make_delta_rpm ($$) {
    @_ == 2 or return 0;
    -e $_[0] && -e $_[1] && -x $MAKEDELTARPM or return 0;
    my @id;
    my $urpm = new URPM;
    foreach my $i (0, 1) {
	($id[$i]) = $urpm->parse_rpm($_[$i]);
	defined $id[$i] or return 0;
    }
    my $oldpkg = $urpm->{depslist}[$id[0]];
    my $newpkg = $urpm->{depslist}[$id[1]];
    $oldpkg->arch eq $newpkg->arch or return 0;
    #- construct filename of the deltarpm
    my $patchrpm = $oldpkg->name . '-' . $oldpkg->version . '-' . $oldpkg->release . '_' . $newpkg->version . '-' . $newpkg->release . '.' . $oldpkg->arch . '.delta.rpm';
    !system($MAKEDELTARPM, @_, $patchrpm);
}

1;
