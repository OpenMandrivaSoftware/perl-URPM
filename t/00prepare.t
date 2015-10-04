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
system(rpmbuild => '--define', "_topdir $pwd/tmp/", '--define', "_rpmdir $pwd/tmp/RPMS", '--define', '_build_name_fmt %%{ARCH}/%{___NVRA}.rpm', '--define', '_rpmfilename %{_build_name_fmt}', '-bb', 'test-rpm.spec');
ok( -f "$pwd/tmp/RPMS/noarch/test-rpm-1.0-1-mdk2013.0.noarch.rpm", 'rpm created' );

