package URPM;

use strict;

# Olivier Thauvin <thauvin@aerov.jussieu.fr>
# This package extend URPM functions to permit
# URPM low level query on rpm header
# $Id$

# tag2id
# INPUT array of rpm tag name
# Return an array of ID tag

sub tag2id {
	my %taglist = URPM::list_rpm_tag;
	map { $taglist{uc("RPMTAG_$_")} || undef } @_;
}

# id2tag
# INPUT array of rpm id tag
# Return an array of tag name

sub id2tag {
	my @id = @_;
	my %taglist = URPM::list_rpm_tag;
	my @ret;
	foreach my $thisid (@id) {
		my $res = grep { $taglist{$_} == $thisid } keys (%taglist);
		$res =~ s/^RPMTAG_//;
		push (@ret, $res ? $res : undef);
	}
	@ret
}

sub query_pkg {
   my ($urpm, $pkg, $query) = @_;
   my @tags = map {
	   [ $pkg->get_tag(tag2id($_)) ]
   } $query =~ m/\%\{([^{}]*)\}*/g;

   $query =~ s/\%\{[^{}]*\}/%s/g;
   $query =~ s/\\n/\n/g;
   $query =~ s/\\t/\t/g;
   my ($max, @res) = 0;

   foreach (@tags) { $max < $#{$_} and $max = $#{$_} };
   
   foreach my $i (0 .. $max) {
	   push(@res, sprintf($query, map { ${$_}[ $#{$_} < $i ? $#{$_} : $i ] } @tags));
   }
   @res	   
}


1;
