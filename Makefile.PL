use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

my $version = `rpm -q --qf '%{VERSION}\n' rpm`;
$version =~ /^(?:[4-9]|\d{2})/ or die "unable to build URPM with too old (or undetected) rpm version $version";

#- search for correct libraries to use (above 4.0.3 is right).
my $libs = $version =~ /^4\.0(?:\.[012])?$/ ?
    '-lrpm -lrpmio -lpopt -lz -lbz2' : '-lrpm -lrpmio -lrpmdb -lpopt -lz -lbz2';
my $define = $version =~ /^(?:4\.[2-9]|[5-9]|\d{2})/ ? '-DRPM_42' : '';

WriteMakefile(
    'NAME'      => 'URPM',
    'CCFLAGS'   => '-Wall',
    'OPTIMIZE'  => '-O3 -fomit-frame-pointer -fno-exceptions -fno-rtti -pipe -s -ffast-math -fexpensive-optimizations',
    'MAKEFILE'  => 'Makefile',
    'OBJECT'    => 'URPM.o',
    'VERSION_FROM'   => 'URPM.pm',
    'LIBS'      => [ $libs ],   # e.g., '-lm' 
    'DEFINE'    => $define,
    'INC'       => '-I/usr/include/rpm',     # e.g., '-I/usr/include/other' 
);
