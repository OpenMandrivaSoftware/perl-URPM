use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile(
    'NAME'      => 'URPM',
    'OPTIMIZE'  => '-O3 -fomit-frame-pointer -fno-exceptions -fno-rtti -pipe -s -ffast-math -fexpensive-optimizations',
    'MAKEFILE'  => 'Makefile',
    'OBJECT'    => 'URPM.o',
    'VERSION_FROM'   => 'URPM.pm',
    'LIBS'      => ['-lrpm -lrpmio -lrpmdb -lpopt -lz -lbz2'],   # e.g., '-lm' 
    'INC'       => '-I/usr/include/rpm',     # e.g., '-I/usr/include/other' 
);
