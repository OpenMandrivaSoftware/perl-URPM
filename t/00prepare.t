#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 1;
use Cwd;

chdir 't' if -d 't';
my $pwd = Cwd::cwd();
mkdir "tmp";
for (qw(BUILD SOURCES RPMS RPMS/noarch)) {
    mkdir "$pwd/tmp/$_";
}
# locally build a test rpm
system(rpmbuild => '--define', "_topdir $pwd/tmp/", '-bb', 'test-rpm.spec');
ok( -f "$pwd/tmp/RPMS/noarch/test-rpm-1.0-1mdk.noarch.rpm", 'rpm created' );

