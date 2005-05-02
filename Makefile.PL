use ExtUtils::MakeMaker;

my $version = `rpm --version`;
$version =~ s/RPM version //;
$version =~ /^(?:4\.[2-9]|[5-9]|\d{2})/ 
    or die "unable to build URPM with too old (or undetected) rpm version $version";

my $libs = '-lrpm -lrpmio -lrpmdb -lpopt -lz -lbz2';

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
    'INC'       => '-I/usr/include/rpm',
    INSTALLDIRS => 'vendor',
);
