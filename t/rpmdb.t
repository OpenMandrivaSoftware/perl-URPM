
use strict ;
use warnings ;

sub ok {
    my ($no, $ok) = @_ ;

    print "ok $no\n" if $ok ;
    print "not ok $no\n" unless $ok ;
    printf "# Failed test at line %d\n", (caller)[2] unless $ok ;
}

use URPM;

print "1..5\n";

my $db;
ok(1, $db = URPM::DB::open);

my @all_pkgs_extern = sort { $a cmp $b } split '\n', `rpm -qa`;
ok(2, @all_pkgs_extern > 0);

my @all_pkgs;
my $count = $db->traverse(sub {
			      my ($pkg) = @_;
			      my ($name, $version, $release, $arch) = $pkg->fullname;
			      $arch or return;
			      push @all_pkgs, "$name-$version-$release";
			  });
ok(3, $count == @all_pkgs_extern);
ok(4, $count == @all_pkgs);

my @all_pkgs_sorted = sort { $a cmp $b } @all_pkgs;
my $bad_pkgs = 0;
foreach (0..$#all_pkgs_sorted) {
    $all_pkgs_sorted[$_] eq $all_pkgs_extern[$_] or ++$bad_pkgs;
}
ok(5, $bad_pkgs == 0);

