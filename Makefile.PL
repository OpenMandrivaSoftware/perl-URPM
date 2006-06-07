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
$version =~ s/RPM version //;
$version =~ /^(?:4\.[2-9]|[5-9]|\d{2})/ 
    or die "Unable to build URPM with too old (or undetected) rpm version $version\n";
print "Found RPM version $version\n";

# directory where to build an rpm of this
my $rpmtopdir = `$rpm_path --eval '%{_topdir}'`;
chomp $rpmtopdir;

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
.PHONY: ChangeLog rpmdist srpm rpm

ChangeLog:
	svn2cl --accum --strip-prefix=soft/rpm/perl-URPM/trunk --authors ${commonusername}username.xml
	rm -f *.bak

rpmdist: dist
	cp -f perl-URPM.spec $rpmtopdir/SPECS
	mv -f URPM-*.tar.bz2 $rpmtopdir/SOURCES

srpm: rpmdist
	rpmbuild -bs --clean --rmsource $rpmtopdir/SPECS/perl-URPM.spec

rpm: rpmdist
	rpmbuild -ba --clean --rmsource $rpmtopdir/SPECS/perl-URPM.spec
**MM**
}

my $ccflags = '-Wall -fno-strict-aliasing';
if ($version =~ /^4\.(4\.[5-9]$|4\.\d\d|[5-9]\.|\d\d)/) {
    $ccflags .= ' -DRPM_CALLBACK_LONGLONG';
}
if ($version eq '4.4.6') {
    $ccflags .= ' -DRPM_446';
}

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
