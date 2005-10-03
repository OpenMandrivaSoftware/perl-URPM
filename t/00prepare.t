#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 1;

chdir 't' if -d 't';
for (qw(BUILD RPMS RPMS/noarch)) {
    mkdir $_;
}
# locally build a test rpm
system(rpmbuild => '--define', '_topdir .', '-bb', '--clean', '../test-rpm.spec');
ok( -f 'RPMS/noarch/test-rpm-1.0-1mdk.noarch.rpm', 'rpm created' );
