use ExtUtils::MakeMaker;

my $version = `rpm -q --qf '%{VERSION}' rpm`;
$version =~ /^(?:[4-9]|\d{2})/
    or die "Unable to build URPM with too old (or undetected) rpm version $version\n";

#- search for correct libraries to use (above 4.0.3 is right).
my $libs = $version =~ /^4\.0(?:\.[012])?$/ ?
    '-lrpm -lrpmio -lpopt -lz -lbz2' : '-lrpm -lrpmio -lrpmdb -lpopt -lz -lbz2';
my $define = $version =~ /^(?:4\.[2-9]|[5-9]|\d{2})/ ? '-DRPM_42' : '';

sub MY::postamble {
    <<MAKECHANGELOG;
.PHONY: ChangeLog

ChangeLog:
	cvs2cl -W 400 -I ChangeLog --accum -U ../common/username
	rm -f *.bak
MAKECHANGELOG
}

WriteMakefile(
    'NAME'      => 'URPM',
    'CCFLAGS'   => '-Wall',
    'OPTIMIZE'  => '-O3 -fomit-frame-pointer -fno-exceptions -pipe -s -ffast-math -fexpensive-optimizations',
    'MAKEFILE'  => 'Makefile',
    'OBJECT'    => 'URPM.o',
    'VERSION_FROM'   => 'URPM.pm',
    'LIBS'      => [ $libs ],
    'DEFINE'    => $define,
    'INC'       => '-I/usr/include/rpm',
    INSTALLDIRS => 'vendor',
);
