package URPM;

use strict;

# Olivier Thauvin <thauvin@aerov.jussieu.fr>
# This package extend URPM functions to permit
# URPM low level query on rpm header
# $Id$

# RPMTAG_ list from rpmlib.h

my %taglist = (
    NAME  		=> 1000,
    VERSION		=> 1001,
    RELEASE		=> 1002,
    EPOCH   		=> 1003,
    SUMMARY		=> 1004,
    DESCRIPTION		=> 1005,
    BUILDTIME		=> 1006,
    BUILDHOST		=> 1007,
    INSTALLTIME		=> 1008,
    SIZE		=> 1009,
    DISTRIBUTION	=> 1010,
    VENDOR		=> 1011,
    GIF			=> 1012,
    XPM			=> 1013,
    LICENSE		=> 1014,
    PACKAGER		=> 1015,
    GROUP		=> 1016,

    CHANGELOG		=> 1017, 

    SOURCE		=> 1018,
    PATCH		=> 1019,
    URL			=> 1020,
    OS			=> 1021,
    ARCH		=> 1022,
    PREIN		=> 1023,
    POSTIN		=> 1024,
    PREUN		=> 1025,
    POSTUN		=> 1026,
    OLDFILENAMES	=> 1027, 
    FILESIZES		=> 1028,
    FILESTATES		=> 1029,
    FILEMODES		=> 1030,
    FILEUIDS		=> 1031, 
    FILEGIDS		=> 1032, 
    FILERDEVS		=> 1033,
    FILEMTIMES		=> 1034,
    FILEMD5S		=> 1035,
    FILELINKTOS		=> 1036,
    FILEFLAGS		=> 1037,

    ROOT		=> 1038, 

    FILEUSERNAME	=> 1039,
    FILEGROUPNAME	=> 1040,

    EXCLUDE		=> 1041, 
    EXCLUSIVE		=> 1042, 

    ICON		=> 1043,
    SOURCERPM		=> 1044,
    FILEVERIFYFLAGS	=> 1045,
    ARCHIVESIZE		=> 1046,
    PROVIDENAME		=> 1047,
    REQUIREFLAGS	=> 1048,
    REQUIRENAME		=> 1049,
    REQUIREVERSION	=> 1050,
    NOSOURCE		=> 1051, 
    NOPATCH		=> 1052, 
    CONFLICTFLAGS	=> 1053,
    CONFLICTNAME	=> 1054,
    CONFLICTVERSION	=> 1055,
    DEFAULTPREFIX	=> 1056, 
    BUILDROOT		=> 1057, 
    INSTALLPREFIX	=> 1058, 
    EXCLUDEARCH		=> 1059,
    EXCLUDEOS		=> 1060,
    EXCLUSIVEARCH	=> 1061,
    EXCLUSIVEOS		=> 1062,
    AUTOREQPROV		=> 1063, 
    RPMVERSION		=> 1064,
    TRIGGERSCRIPTS	=> 1065,
    TRIGGERNAME		=> 1066,
    TRIGGERVERSION	=> 1067,
    TRIGGERFLAGS	=> 1068,
    TRIGGERINDEX	=> 1069,
    VERIFYSCRIPT	=> 1079,
    CHANGELOGTIME	=> 1080,
    CHANGELOGNAME	=> 1081,
    CHANGELOGTEXT	=> 1082,

    BROKENMD5		=> 1083, 

    PREREQ		=> 1084, 
    PREINPROG		=> 1085,
    POSTINPROG		=> 1086,
    PREUNPROG		=> 1087,
    POSTUNPROG		=> 1088,
    BUILDARCHS		=> 1089,
    OBSOLETENAME	=> 1090,
    VERIFYSCRIPTPROG	=> 1091,
    TRIGGERSCRIPTPROG	=> 1092,
    DOCDIR		=> 1093, 
    COOKIE		=> 1094,
    FILEDEVICES		=> 1095,
    FILEINODES		=> 1096,
    FILELANGS		=> 1097,
    PREFIXES		=> 1098,
    INSTPREFIXES	=> 1099,
    TRIGGERIN		=> 1100, 
    TRIGGERUN		=> 1101, 
    TRIGGERPOSTUN	=> 1102, 
    AUTOREQ		=> 1103, 
    AUTOPROV		=> 1104, 

    CAPABILITY		=> 1105, 

    SOURCEPACKAGE	=> 1106, 

    OLDORIGFILENAMES	=> 1107, 

    BUILDPREREQ		=> 1108, 
    BUILDREQUIRES	=> 1109, 
    BUILDCONFLICTS	=> 1110, 

    BUILDMACROS		=> 1111, 

    PROVIDEFLAGS	=> 1112,
    PROVIDEVERSION	=> 1113,
    OBSOLETEFLAGS	=> 1114,
    OBSOLETEVERSION	=> 1115,
    DIRINDEXES		=> 1116,
    BASENAMES		=> 1117,
    DIRNAMES		=> 1118,
    ORIGDIRINDEXES	=> 1119, 
    ORIGBASENAMES	=> 1120, 
    ORIGDIRNAMES	=> 1121, 
    OPTFLAGS		=> 1122,
    DISTURL		=> 1123,
    PAYLOADFORMAT	=> 1124,
    PAYLOADCOMPRESSOR	=> 1125,
    PAYLOADFLAGS	=> 1126,
    INSTALLCOLOR	=> 1127, 
    INSTALLTID		=> 1128,
    REMOVETID		=> 1129,

    SHA1RHN		=> 1130, 

    RHNPLATFORM		=> 1131,
    PLATFORM		=> 1132,
    PATCHESNAME		=> 1133, 
    PATCHESFLAGS	=> 1134, 
    PATCHESVERSION	=> 1135, 
    CACHECTIME		=> 1136,
    CACHEPKGPATH	=> 1137,
    CACHEPKGSIZE	=> 1138,
    CACHEPKGMTIME	=> 1139,
    FILECOLORS		=> 1140,
    FILECLASS		=> 1141,
    CLASSDICT		=> 1142,
    FILEDEPENDSX	=> 1143,
    FILEDEPENDSN	=> 1144,
    DEPENDSDICT		=> 1145,
    SOURCEPKGID		=> 1146,	
);

# tag2id
# INPUT array of rpm tag name
# Return an array of ID tag

sub tag2id {
	map { $taglist{uc($_)} || undef } @_;
}

# id2tag
# INPUT array of rpm id tag
# Return an array of tag name

sub id2tag {
	my @id = @_;
	my @ret;
	foreach my $thisid (@id) {
		my $res = grep { $taglist{$_} == $thisid } keys (%taglist);
		push (@ret, $res ? $res : undef);
	}
	@ret
}

1;
