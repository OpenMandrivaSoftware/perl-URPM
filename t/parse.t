#!/usr/bin/perl

# $Id$

use strict ;
use warnings ;
use Test::More tests => 13;
use URPM;
use URPM::Build;
use URPM::Query;

my $a = new URPM;
ok($a);

my ($start, $end) = $a->parse_rpms_build_headers(rpms => [ "test-rpm-1.0-1mdk.noarch.rpm" ], keep_all_tags => 1);
ok(@{$a->{depslist}} == 1);
my $pkg = $a->{depslist}[0];
ok($pkg);
ok($a->list_rpm_tag);
ok($pkg->get_tag(1000) eq 'test-rpm');
ok($pkg->get_tag(1001) eq '1.0');
ok($pkg->get_tag(1002) eq '1mdk');

$a->build_hdlist(start  => 0,
                    end    => $#{$a->{depslist}},
                    hdlist => 'hdlist.cz',
                    ratio  => 9);

ok(-f 'hdlist.cz');

my $b = new URPM;
my ($start, $end) = $b->parse_hdlist('hdlist.cz', keep_all_tags => 1);
ok(@{$b->{depslist}} == 1);
my $pkg = $b->{depslist}[0];
ok($pkg);
ok($pkg->get_tag(1000) eq 'test-rpm');
ok($pkg->get_tag(1001) eq '1.0');
ok($pkg->get_tag(1002) eq '1mdk');





