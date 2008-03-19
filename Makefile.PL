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

sub hexversion {
	my ($major, $minor, $micro) = (@_[0] =~ /(\d+)\.(\d+)\.?(\d+)?/);
	return int($major<<16) + int($minor<<8) + int($micro<<0)
}

my $version = `LC_ALL=C $rpm_path --version`;
# fix compiling with RCs:
$version =~ s/(-.*)|(\.DEVEL)//;
chomp $version;
$version =~ s/(RPM version )|(rpm \(RPM\) )//;
my $hversion = hexversion($version);
$hversion ge hexversion(4.2) or die "Unable to build URPM with too old (or undetected) rpm version $version\n";

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
#print $hversion;
if ($hversion ge hexversion(4.4.90) && $hversion lt hexversion(4.5)) {
    # rpm.org version
    push @rpmflags, "-DRPM_ORG";
} else {
    # rpm5.org version
	push @rpmflags, "-DRPM_VERSION_CODE=$hversion";
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
