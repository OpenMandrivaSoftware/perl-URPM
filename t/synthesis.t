#!/usr/bin/perl

use strict ;
use warnings ;

sub ok {
    my ($no, $ok) = @_ ;

    print "ok $no\n" if $ok ;
    print "not ok $no\n" unless $ok ;
    printf "# Failed test at line %d\n", (caller)[2] unless $ok ;
}

use URPM;

my $file1 = 'synthesis.sample.cz';

local *F;
open F, "| gzip -9 >$file1";
print F q{
glibc-devel@provides@glibc-devel == 6:2.2.4-25mdk
glibc-devel@requires@/sbin/install-info@glibc == 2.2.4@kernel-headers@kernel-headers >= 2.2.1@/bin/sh@/bin/sh@/bin/sh@rpmlib(PayloadFilesHavePrefix) <= 4.0-1@rpmlib(CompressedFileNames) <= 3.0.4-1
glibc-devel@conflicts@texinfo < 3.11@gcc < 2.96-0.50mdk
glibc-devel@obsoletes@libc-debug@libc-headers@libc-devel@linuxthreads-devel@glibc-debug
glibc-devel@info@glibc-devel-2.2.4-25mdk.i586@6@45692097@Development/C
};
close F;

print "1..80\n";

my $a = new URPM;
ok(1, $a);

my ($first, $end) = $a->parse_synthesis($file1);
ok(2, $first == 0 && $end == 0);
ok(3, @{$a->{depslist}} == 1);
ok(4, keys(%{$a->{provides}}) == 3);
ok(5, defined $a->{provides}{'glibc-devel'});
ok(6, exists $a->{provides}{'/bin/sh'});
ok(7, ! defined $a->{provides}{'/bin/sh'});
ok(8, exists $a->{provides}{'/sbin/install-info'});
ok(9, ! defined $a->{provides}{'/sbin/install-info'});

my $pkg = $a->{depslist}[0];
ok(10, $pkg);
ok(11, $pkg->name eq 'glibc-devel');
ok(12, $pkg->version eq '2.2.4');
ok(13, $pkg->release eq '25mdk');
ok(14, $pkg->arch eq 'i586');
ok(15, $pkg->fullname eq 'glibc-devel-2.2.4-25mdk.i586');

my ($name, $version, $release, $arch, @l) = $pkg->fullname;
ok(16, @l == 0);
ok(17, $name eq 'glibc-devel');
ok(18, $version eq '2.2.4');
ok(19, $release eq '25mdk');
ok(20, $arch eq 'i586');

ok(21, $pkg->epoch == 6);
ok(22, $pkg->size == 45692097);
ok(23, $pkg->group eq 'Development/C');
ok(24, $pkg->filename eq 'glibc-devel-2.2.4-25mdk.i586.rpm');
ok(25, defined $pkg->id);
ok(26, $pkg->id == 0);
ok(27, $pkg->set_id(6) == 0);
ok(28, $pkg->id == 6);
ok(29, $pkg->set_id == 6);
ok(30, ! defined $pkg->id);
ok(31, ! defined $pkg->set_id(0));
ok(32, defined $pkg->id);
ok(33, $pkg->id == 0);

my @obsoletes = $pkg->obsoletes;
ok(34, @obsoletes == 5);
ok(35, $obsoletes[0] eq 'libc-debug');
ok(36, $obsoletes[4] eq 'glibc-debug');

my @conflicts = $pkg->conflicts;
ok(37, @conflicts == 2);
ok(38, $conflicts[0] eq 'texinfo < 3.11');
ok(39, $conflicts[1] eq 'gcc < 2.96-0.50mdk');

my @requires = $pkg->requires;
ok(40, @requires == 9);
ok(41, $requires[0] eq '/sbin/install-info');
ok(42, $requires[8] eq 'rpmlib(CompressedFileNames) <= 3.0.4-1');

my @provides = $pkg->provides;
ok(43, @provides == 1);
ok(44, $provides[0] eq 'glibc-devel == 6:2.2.4-25mdk');

my @files = $pkg->files;
ok(45, @files == 0);

ok(46, $pkg->compare("6:2.2.4-25mdk") == 0);
ok(47, $pkg->compare("2.2.4-25mdk") == 0);
ok(48, $pkg->compare("2.2.4") == 0);
ok(49, $pkg->compare("2.2.3") > 0);
ok(50, $pkg->compare("2.2") > 0);
ok(51, $pkg->compare("2") > 0);
ok(52, $pkg->compare("2.2.4.0") < 0);
ok(53, $pkg->compare("2.2.5") < 0);
ok(54, $pkg->compare("2.1.7") > 0);
ok(55, $pkg->compare("2.3.1") < 0);
ok(56, $pkg->compare("2.2.31") < 0);
ok(57, $pkg->compare("2.2.4-25") > 0);
ok(58, $pkg->compare("2.2.4-25.1mdk") < 0);
ok(59, $pkg->compare("2.2.4-24mdk") > 0);
ok(60, $pkg->compare("2.2.4-26mdk") < 0);
ok(61, $pkg->compare("6:2.2.4-26mdk") < 0);
ok(62, $pkg->compare("7:2.2.4-26mdk") < 0);
ok(63, $pkg->compare("7:2.2.4-24mdk") < 0);

ok(64, $a->traverse() == 1);

my $test = 0;
ok(65, $a->traverse(sub { my ($pkg) = @_; $test = $pkg->name eq 'glibc-devel' }) == 1);
ok(66, $test);
ok(67, $a->traverse_tag('name', [ 'glibc-devel' ]) == 1);
ok(68, $a->traverse_tag('name', [ 'glibc' ]) == 0);

$test = 0;
ok(69, $a->traverse_tag('name', [ 'glibc-devel' ], sub { my ($pkg) = @_; $test = $pkg->name eq 'glibc-devel' }) == 1);
ok(70, $test);

@conflicts = $pkg->conflicts_nosense;
ok(71, @conflicts == 2);
ok(72, $conflicts[0] eq 'texinfo');
ok(73, $conflicts[1] eq 'gcc');

@requires = $pkg->requires_nosense;
ok(74, @requires == 9);
ok(75, $requires[0] eq '/sbin/install-info');
ok(76, $requires[1] eq 'glibc');
ok(77, $requires[3] eq 'kernel-headers');
ok(78, $requires[8] eq 'rpmlib(CompressedFileNames)');

@provides = $pkg->provides_nosense;
ok(79, @provides == 1);
ok(80, $provides[0] eq 'glibc-devel');

