#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 1;
use Cwd;

chdir 't' if -d 't';
for (qw(BUILD RPMS RPMS/noarch tmp)) {
    mkdir $_;
}
# locally build a test rpm
system(rpmbuild => '--define', '_topdir .', '--define', '_sourcedir .', '--define', '_tmppath ' . Cwd::cwd() . '/tmp/', '-bb', 'test-rpm.spec');
ok( -f 'RPMS/noarch/test-rpm-1.0-1mdk.noarch.rpm', 'rpm created' );

END { system('rm -rf BUILD tmp') };
