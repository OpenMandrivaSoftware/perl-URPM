#!/usr/bin/perl

use strict ;
use warnings ;
use Test::More tests => 15;
use File::Copy qw (copy);
use File::Path qw (make_path remove_tree);
use Cwd qw (abs_path);
use URPM;

my $db;

END {
    $db = URPM::DB::close($db);
    remove_tree("tmp"); 
}

my ($count, @all_pkgs_extern, @all_pkgs);
my ($pkg_perl, $count_perl, $pkg_perl_extern);
{
    my $db;
    ok($db = URPM::DB::open, 'DB opened');

    @all_pkgs_extern = sort { $a cmp $b } split /\n/ => qx(rpm -qa --nosignature --qf '%{name}-%{version}-%{release}\n');
    ok(@all_pkgs_extern > 0, 'There are RPMs');

    $count = $db->traverse(sub {
	    my ($pkg) = @_;
	    my ($name, $version, $release, $arch) = $pkg->fullname;
	    #- arch is void for -pubkey- package.
	    my $fullname = "$name-$version-$release";
	    push @all_pkgs, $fullname;
	    if ($name eq 'perl') { $pkg_perl_extern = $fullname }
	});

    $count_perl = $db->traverse_tag('name', ['perl'], sub {
	    my ($pkg) = @_;
	    my ($name, $version, $release) = $pkg->fullname;
	    $pkg_perl = "$name-$version-$release";
	});
}
is($count, @all_pkgs_extern,
    'traversed same num of packages than given by rpm -qa');
is($count, @all_pkgs,
    'traversed each package once');
is($count_perl, 1, q(there's exactly 1 "perl" package));
is($pkg_perl, $pkg_perl_extern, '... with the correct fullname');

my @all_pkgs_sorted = sort { $a cmp $b } @all_pkgs;
my $bad_pkgs = 0;
foreach (0..$#all_pkgs_sorted) {
    $all_pkgs_sorted[$_] eq $all_pkgs_extern[$_] and next;
    diag($all_pkgs_extern[$_] . " vs " . $all_pkgs_sorted[$_]);
    ++$bad_pkgs;
}
is($bad_pkgs, 0, 'no mismatch between package lists');

my $tmp = abs_path("t/res/tmp");
my $tmpdbpath = $tmp . URPM::expand("%{_dbpath}");
my $rpmdb_btreebig = abs_path("t/res/rpmdb_btreebig");
my $rpmdb_hashlittle = abs_path("t/res/rpmdb_hashlittle");
my @btreebig = ("btree", "bigendian");
my @hashlittle = ("hash", "littleendian");

remove_tree($tmp);
make_path($tmpdbpath);
copy("$rpmdb_btreebig/Packages", "$tmpdbpath/Packages");
my @check = URPM::DB::info($tmp);
is_deeply(\@check, \@btreebig, "checking rpmdb (btree, big endian) type & ordering ok");
ok(URPM::DB::convert($tmp, "hash", -1, 0), "converting to hash, little endian ordering");
@check = URPM::DB::info($tmp);
is_deeply(\@check, \@hashlittle, "conversion to hash, little endian");

remove_tree($tmp);
make_path($tmpdbpath);
copy("$rpmdb_hashlittle/Packages", "$tmpdbpath/Packages");
@check = URPM::DB::info($tmp);
is_deeply(\@check, \@hashlittle, "checking rpmdb (hash, little endian) type & ordering ok");
ok(URPM::DB::convert($tmp, "btree", 1, 1), "converting to btree, big endian ordering");
@check = URPM::DB::info($tmp);
is_deeply(\@check, \@btreebig, "conversion to btree, big endian");

ok($db = URPM::DB::open($tmp), 'newly converted DB opened');
$db->traverse_tag("name", ["null-dummy"], sub {
	my ($pkg) = @_;
	is($pkg->name, "null-dummy", "querying newly converted DB");
    });

