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

# directory where to build an rpm of this
my $rpmtopdir = `$rpm_path --eval '%{_topdir}'`;
chomp $rpmtopdir;

sub MY::postamble {
    <<"**MM**";
.PHONY: ChangeLog rpmdist srpm rpm

ChangeLog:
	cvs2cl -W 400 -I ChangeLog --accum -U ../common/username
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

WriteMakefile(
    NAME	=> 'URPM',
    CCFLAGS	=> '-Wall',
    OPTIMIZE	=> '-O3 -fomit-frame-pointer -fno-exceptions -pipe -s -ffast-math -fexpensive-optimizations',
    VERSION_FROM	=> 'URPM.pm',
    LIBS	=> [ '-lrpm -lrpmio -lrpmdb -lpopt -lz -lbz2' ],
    INC		=> '-I/usr/include/rpm',
    dist	=> { COMPRESS => "bzip2", SUFFIX => ".bz2" },
);
