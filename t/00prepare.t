#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 1;
use Cwd;

@tmpdirs = qw(BUILD SOURCES RPMS RPMS/noarch tmp);

chdir 't' if -d 't';
mkdir $_ foreach @tmpdirs;

# locally build a test rpm
system(rpmbuild => '--define', '_topdir ' . Cwd::cwd(), '--define', '_tmppath ' . Cwd::cwd() . '/tmp/', '-bb', 'test-rpm.spec');
ok( -f 'RPMS/noarch/test-rpm-1.0-1mdk.noarch.rpm', 'rpm created' );

END { system('rm', '-rf', @tmpdirs) };
