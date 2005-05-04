package URPM;

use strict;
use DynaLoader;

# different files, but same package
# require them here to avoid dependencies
use URPM::Build;
use URPM::Resolve;
use URPM::Signature;

our @ISA = qw(DynaLoader);
our $VERSION = '1.20';

URPM->bootstrap($VERSION);

sub new {
    my ($class, %options) = @_;
    my $self = bless {
	depslist => [],
	provides => {},
    }, $class;
    $self->{nofatal} = 1 if $options{nofatal};
    $self;
}

sub set_nofatal { $_[0]->{nofatal} = $_[1] }

sub search {
    my ($urpm, $name, %options) = @_;
    my $best;

    #- tries other alternative if no strict searching.
    unless ($options{strict_name}) {
	if ($name =~ /^(.*)-([^\-]*)-([^\-]*)\.([^\.\-]*)$/) {
	    foreach (keys %{$urpm->{provides}{$1} || {}}) {
		my $pkg = $urpm->{depslist}[$_];
		$pkg->fullname eq $name and return $pkg;
	    }
	}
	unless ($options{strict_fullname}) {
	    if ($name =~ /^(.*)-([^\-]*)-([^\-]*)$/) {
		foreach (keys %{$urpm->{provides}{$1} || {}}) {
		    my $pkg = $urpm->{depslist}[$_];
		    my ($n, $v, $r, $a) = $pkg->fullname;
		    $options{src} && $a eq 'src' || $pkg->is_arch_compat or next;
		    "$n-$v-$r" eq $name or next;
		    !$best || $pkg->compare_pkg($best) > 0 and $best = $pkg;
		}
		$best and return $best;
	    }
	    if ($name =~ /^(.*)-([^\-]*)$/) {
		foreach (keys %{$urpm->{provides}{$1} || {}}) {
		    my $pkg = $urpm->{depslist}[$_];
		    my ($n, $v, undef, $a) = $pkg->fullname;
		    $options{src} && $a eq 'src' || $pkg->is_arch_compat or next;
		    "$n-$v" eq $name or next;
		    !$best || $pkg->compare_pkg($best) > 0 and $best = $pkg;
		}
		$best and return $best;
	    }
	}
    }

    unless ($options{strict_fullname}) {
	foreach (keys %{$urpm->{provides}{$name} || {}}) {
	    my $pkg = $urpm->{depslist}[$_];
	    my ($n, undef, undef, $a) = $pkg->fullname;
	    $options{src} && $a eq 'src' || $pkg->is_arch_compat or next;
	    $n eq $name or next;
	    !$best || $pkg->compare_pkg($best) > 0 and $best = $pkg;
	}
    }

    return $best;
}

#- Olivier Thauvin:
#- Returns @$listid, $start .. $end or the whole deplist id
#- according to the given args
sub build_listid {
    my ($urpm, $start, $end, $listid) = @_;

    @{$listid || []} > 0 ? @{$listid} :
        (($start || 0) .. (defined($end) ? $end : $#{$urpm->{depslist}}));
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
    my $count = 0; 
    my %names;

    if (@{$names || []}) {
	if ($tag eq 'name') {
	    foreach my $n (@$names) {
		foreach (keys %{$urpm->{provides}{$n} || {}}) {
		    my $p = $urpm->{depslist}[$_];
		    $p->name eq $n or next;
		    $callback and $callback->($p);
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
	} else {
	    @names{@$names} = ();
	    if ($tag eq 'whatrequires') {
		foreach (@{$urpm->{depslist} || []}) {
		    if (grep { exists $names{$_} } $_->requires_nosense) {
			$callback and $callback->($_);
			++$count;
		    }
		}
	    } elsif ($tag eq 'whatconflicts') {
		foreach (@{$urpm->{depslist} || []}) {
		    if (grep { exists $names{$_} } $_->conflicts_nosense) {
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
		    if (grep { exists $names{$_} } $_->files, grep { m!^/! } $_->provides_nosense) {
			$callback and $callback->($_);
			++$count;
		    }
		}
	    } else {
		die "unknown tag";
	    }
	}
    }

    $count;
}

package URPM::Package;
our @ISA = qw(); # help perl_checker

package URPM::Transaction;
our @ISA = qw(); # help perl_checker

package URPM::DB;
our @ISA = qw(); # help perl_checker

1;

__END__

=head1 NAME

URPM - Perl module to manipulate RPM files

=head1 SYNOPSIS

    use URPM;

    # using the local RPM database
    my $db = URPM::DB::open();
    $db->traverse(sub {
	my ($package) = @_; # this is a URPM::Package object
	print $package->filename, "\n";
	# ...
    });

    # loading and parsing a synthesis file
    my $urpm = new URPM;
    $urpm->parse_synthesis("synthesis.sample.cz");
    $urpm->traverse(sub {
	# retrieve all packages from the dependency list
	# ...
    });

=head1 DESCRIPTION

The URPM module allows you to manipulate RPM files, RPM header files and
hdlist files and manage them in memory. It is notably used by the B<urpmi>
utility. It provides four classes : C<URPM>, C<URPM::DB>, C<URPM::Package>,
and C<URPM::Transaction>.

=head2 The URPM class

=over 4

=item new()

The constructor creates a new, empty URPM object. It's a blessed hash that
contains two fields:

B<depslist> is an arrayref containing the list of depending packages (which are
C<URPM::Package> objects).

B<provides> is an hashref containing as keys the list of items provided by the
URPM object.

If the constructor is called with the arguments C<< nofatal => 1 >>, various
fatal error messages are suppressed (file not found in parse_hdlist() and
parse_synthesis()).

=item read_config_files()

Force the re-reading of the RPM configuration files.

=item list_rpm_tag()

Return a hash containing the key/id values of known rpm tags

=item ranges_overlap($range1, $range2 [, $nopromoteepoch])

This utility function compares two version ranges, in order to calculate
dependencies properly. The ranges have roughly the form

    [<|<=|==|=>|>] [epoch:]version[-release]

where epoch, version and release are RPM-style version numbers.

If the optional parameter $nopromoteepoch is true, and if the 2nd range has no
epoch while the first one has one, then the 2nd range is assumed to have an
epoch == 0.

=item $urpm->parse_synthesis($file, [ callback => sub {...} ])

This method gets the B<depslist> and the B<provides> from a synthesis file
and adds them to the URPM object.

=item $urpm->parse_hdlist($file, %options)

This method loads rpm informations from rpm B<headers> contained in an hdlist
file and adds them to the URPM object. Allowed options are 

    packing => 0 / 1
    callback => sub { ... }
    keep_all_tags => 0 / 1

Return value is an array of first and last id parsed.
    
=item $urpm->parse_rpms($files, %options)

This method loads rpm informations from rpm B<headers> and adds them to
the URPM object.

Return value is an array of first and last id parsed.

=item $urpm->parse_rpm($file, %options)

This method gets the B<depslist> and the B<provides> from an RPM file
and adds them to the URPM object. Allowed options are

    packing => 0 / 1
    keep_all_tags => 0 / 1
    callback => sub { ... }

=item $urpm->search($name, %options)

Search an RPM by name or by part of name in the list of RPMs represented by
this $urpm. The behaviour of the search is influenced by several options:

    strict_name => 0 / 1
    strict_fullname => 0 / 1
    src => 0 / 1

=item $urpm->traverse($callback)

Executes the callback for each package in the depslist, passing a
C<URPM::Package> object as argument the callback.

=item $urpm->traverse_tag($tag, $names, $callback)

$tag may be one of C<name>, C<whatprovides>, C<whatrequires>, C<whatconflicts>,
C<group>, C<triggeredby>, or C<path>.
$names is a reference to an array, holding the acceptable values of the said
tag for the searched variables.
Then, $callback is called for each matching package in the depslist.

=item $urpm->verify_rpm($file, %options)

Verifies an RPM file.
Recognized options are:

    db => $urpm_db
    nopgp => 0 / 1
    nogpg => 0 / 1
    nomd5 => 0 / 1
    norsa => 0 / 1
    nodsa => 0 / 1
    nodigests => 0 / 1
    tmp_filename => '...'
    nosignatures => 0 / 1 (equivalent to nopgp = nogpg = norsa = nodsa = 1)

=item $urpm->import_pubkey(%options)

    db => $urpm_db
    root => '...'
    block => '...'
    filename => '...'

=back

=head2 The URPM::DB class

=over 4

=item open($prefix, $write_perm)

Returns a new C<URPM::DB> object pointing on the local RPM database.

$prefix defaults to C<""> and indicates the RPM DB root directory prefix if
any. (See the B<--root> option to rpm(1)).

$write_perm is a boolean that defaults to false, and that indicates whether
the RPM DB should be open in read/write mode.

=item rebuild($prefix)

Rebuilds the RPM database (like C<rpm --rebuilddb>). $prefix defaults to C<"">.

=item $db->traverse($callback)

Executes the specified callback (a code reference) for each package
in the DB, passing a C<URPM::Package> object as argument the callback.

=item $db->traverse_tag($tag,$names,$callback)

$tag may be one of C<name>, C<whatprovides>, C<whatrequires>, C<whatconflicts>,
C<group>, C<triggeredby>, or C<path>.
$names is a reference to an array, holding the acceptable values of the said
tag for the searched variables.
Then, $callback is called for each matching package in the DB.

=item $db->create_transaction($prefix)

Creates and returns a new transaction (an C<URPM::Transaction> object) on the
specified DB. For $prefix, cf L<open>.

=back

=head2 The URPM::Package class

Most methods of C<URPM::Package> are accessors for the various properties
of an RPM package.

=over 4

=item $package->arch()

=item $package->build_header($fileno)

=item $package->build_info($fileno, [$provides_files])

=item $package->buildarchs()

=item $package->buildhost()

=item $package->buildtime()

=item $package->changelog_name()

=item $package->changelog_text()

=item $package->changelog_time()

=item $package->compare($evr)

=item $package->compare_pkg($other_pkg)

=item $package->conf_files()

=item $package->conflicts()

=item $package->conflicts_nosense()

=item $package->description()

=item $package->distribution()

=item $package->epoch()

=item $package->excludearchs()

=item $package->exclusivearchs()

=item $package->filename()

=item $package->files()

=item $package->files_flags()

=item $package->files_gid()

=item $package->files_group()

=item $package->files_md5sum()

=item $package->files_mode()

=item $package->files_mtime()

=item $package->files_owner()

=item $package->files_size()

=item $package->files_uid()

=item $package->flag($name)

=item $package->flag_available()

=item $package->flag_base()

=item $package->flag_disable_obsolete()

=item $package->flag_installed()

=item $package->flag_requested()

=item $package->flag_required()

=item $package->flag_selected()

=item $package->flag_skip()

=item $package->flag_upgrade()

=item $package->free_header()

=item $package->fullname()

Returns a 4 element list: name, version, release and architecture in an array context.
Returns a string NAME-VERSION-RELEASE.ARCH in scalar context.

=item $package->get_tag($tagid)

Returns an array containing values of $tagid. $tagid is the numerical value of
rpm tags. See rpmlib.h. 

=item $package->queryformat($format)

Querying the package like rpm --queryformat do. 

The function calls directly the rpmlib, then use header informations, so it 
silently failed if you use synthesis instead of hdlist/rpm/header files or rpmdb.

=item $package->get_tag_modifiers($tagid)

Return an array of human readable view of tag values. $tagid is the numerical value of rpm tags.

=item $package->group()

=item $package->header_filename()

=item $package->id()

=item $package->is_arch_compat()

=item $package->license()

=item $package->name()

=item $package->obsoletes()

=item $package->obsoletes_nosense()

=item $package->obsoletes_overlap($s, [$nopromoteepoch,] [$direction])

=item $package->os()

=item $package->pack_header()

=item $package->packager()

=item $package->provides()

=item $package->provides_nosense()

=item $package->provides_overlap($s, [$nopromoteepoch,] [$direction])

=item $package->rate()

=item $package->release()

=item $package->requires()

=item $package->requires_nosense()

=item $package->rflags()

=item $package->set_flag($name, $value)

=item $package->set_flag_base($value)

=item $package->set_flag_disable_obsolete($value)

=item $package->set_flag_installed($value)

=item $package->set_flag_requested($value)

=item $package->set_flag_required($value)

=item $package->set_flag_skip($value)

=item $package->set_flag_upgrade($value)

=item $package->set_id($id)

=item $package->set_rate($rate)

=item $package->set_rflags(...)

=item $package->size()

=item $package->sourcerpm()

=item $package->summary()

=item $package->update_header($filename, ...)

=item $package->upgrade_files()

=item $package->url()

=item $package->vendor()

=item $package->version()

=back

=head2 The URPM::Transaction class

=over 4

=item $trans->set_script_fd($fileno)

Sets the transaction output filehandle.

=item $trans->add($pkg, %options)

Adds a package to be installed to the transaction represented by $trans.
$pkg is an C<URPM::Package> object.

Options are:

    update => 0 / 1 : indicates whether this is an upgrade
    excludepath => [ ... ]

=item $trans->remove($name)

Adds a package to be erased to the transaction represented by $trans.
$name is the name of the package.

=item $trans->check(%options)

Checks that all dependencies can be resolved in this transaction.

Options are:

    translate_message => 0 / 1 (currently ignored.)

=item $trans->order()

Determines package order in a transaction set according to dependencies.
Returns a boolean indicating success.

=item $trans->run($data, %options)

Runs the transaction.

$data is an arbitrary user-provided piece of data to be passed to callbacks.

Recognized options are:

    callback_close  => sub { ... }
    callback_inst   => sub { ... }
    callback_open   => sub { ... }
    callback_trans  => sub { ... }
    callback_uninst => sub { ... }
    delta => used for progress callbacks (trans, uninst, inst)
    excludedocs => 0 / 1
    force => 0 / 1
    nosize => 0 / 1
    oldpackage => 0 / 1
    test => 0 / 1
    translate_message

They roughly correspond to command-line options to rpm(1).

=back

=head2 Macro handling functions

=over

=item loadmacrosfile($filename)

Load the specified macro file. Sets $! if the file can't be read.

=item expand($name)

Expands the specified macro.

=item add_macro($macro_definition)

Define a macro. For example,

    URPM::add_macro("vendor Mandrakesoft");
    my $vendor = URPM::expand("%vendor");

=item del_macro($name)

Delete a macro.

=item resetmacros()

Destroys macros.

=back

=head1 COPYRIGHT

Copyright 2002-2005 Mandrakesoft

Original author: François Pons

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
