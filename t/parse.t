#!/usr/bin/perl

use strict ;
use warnings ;
use Test::More tests => 4;
use URPM;
use URPM::Build;
use URPM::Query;

my $a = new URPM;
ok($a);

my ($start, $end) = $a->parse_rpms_build_headers(rpms => [ "test-rpm-1.0-1mdk.noarch.rpm" ], keep_all_tags => 1);
ok(@{$a->{depslist}} == 1);
my $pkg = $a->{depslist}[0];
ok($pkg);
ok($pkg->get_tag(1000) eq 'test-rpm');




