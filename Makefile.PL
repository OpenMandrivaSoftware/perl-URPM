use strict;
use ExtUtils::MakeMaker;

# where to find the rpm utility

my $rpm_path = $ENV{RPM_PATH}; # this overrides

unless (defined $rpm_path) {
    for (qw(/bin/rpm /usr/bin/rpm)) {
	if (-x) {
	    $rpm_path = $_;
	    last;
	}
    }
}

defined $rpm_path or die "Can't find rpm on this system\n";

my $version = `LC_ALL=C $rpm_path --version`;
chomp $version;
$version =~ s/RPM version //;
my $pversion = eval "v$version";
$pversion ge v4.2 or die "Unable to build URPM with too old (or undetected) rpm version $version\n";

# to generate the ChangeLog depending on the checkout layout
my $commonusername = "../common/";
-d $commonusername or do {
    $commonusername = "../../common/";
    -d $commonusername or do {
	$commonusername = "../../../common/";
	-d $commonusername or $commonusername = "";
    };
};

sub MY::postamble {
    <<"**MM**";
.PHONY: ChangeLog

ChangeLog:
	LC_ALL=C svn2cl --accum --strip-prefix=soft/rpm/perl-URPM/trunk --authors ${commonusername}username.xml
	rm -f *.bak
**MM**
}

my @rpmflags;
if ($pversion ge v4.4.90 && $pversion lt v4.5) {
    # rpm.org version
    push @rpmflags, '-DRPM_ORG';
} else {
    # rpm5.org version
    if ($pversion ge v4.4.5) {
	push @rpmflags, '-DRPM_CALLBACK_LONGLONG';
    } 
    if ($pversion ge v4.4.6) {
	push @rpmflags, '-DRPM_446';
    }
    if ($pversion ge v4.4.8) {
	push @rpmflags, '-DRPM_448';
    }
    if ($pversion ge v4.5) {
       	push @rpmflags, '-DRPM_450';
    }
}
my $ccflags = join(' ', '-Wall -fno-strict-aliasing', @rpmflags);

print "Found RPM version $version (compiling with flags: $ccflags)\n";

WriteMakefile(
    NAME	=> 'URPM',
    PREREQ_PM	=> {
	'MDV::Packdrakeng' => '1.00',
    },
    CCFLAGS	=> $ccflags,
    VERSION_FROM	=> 'URPM.pm',
    LIBS	=> [ '-lrpm -lrpmio -lrpmdb -lrpmbuild -lpopt -lz' ],
    INC		=> '-I/usr/include/rpm',
    dist	=> { COMPRESS => "bzip2", SUFFIX => ".bz2" },
    realclean	=> { FILES => "t/RPMS/noarch/*" },
);
