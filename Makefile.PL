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

my $version = `pkg-config --modversion rpm`;
my $hversion = hexversion($version);
$hversion ge hexversion("5.3") or die "Unable to build URPM with too old (or undetected) rpm version $version\n";

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

my $ldflags = `pkg-config --libs rpm liblzma`;
chomp($ldflags);
$ldflags .= " -lmagic";
my $includes = `pkg-config --cflags-only-I rpm liblzma`;
my $ccflags = join(' ', '-Wall -Wextra -fno-strict-aliasing -std=gnu99', `pkg-config --cflags-only-other rpm liblzma`);
chomp($ccflags);

print "Found RPM version $version (compiling with flags: $ccflags)\n";

WriteMakefile(
    NAME	=> 'URPM',
    PREREQ_PM	=> {
	'MDV::Packdrakeng' => '1.00',
    },
    CCFLAGS	=> $ccflags,
    VERSION_FROM	=> 'URPM.pm',
    dynamic_lib	=> { OTHERLDFLAGS => $ldflags },
    INC		=> $includes,
    dist	=> { COMPRESS => "xz -f", SUFFIX => ".xz" },
    realclean	=> { FILES => "t/RPMS/noarch/*" },
);
