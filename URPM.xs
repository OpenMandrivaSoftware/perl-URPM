/* Copyright (c) 2002 MandrakeSoft <fpons@mandrakesoft.com>
 * All rights reserved.
 * This program is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <sys/utsname.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <zlib.h>

#undef Fflush
#undef Mkdir
#undef Stat
#include <rpm/rpmlib.h>
#include <rpm/header.h>

struct s_Package {
  char *info;
  char *requires;
  char *obsoletes;
  char *conflicts;
  char *provides;
  char *rates;
  unsigned flag;
  Header h;
};

typedef rpmdb URPM__DB;
typedef struct s_Package* URPM__Package;

#define FLAG_ID             0x00ffffffU
#define FLAG_BASE           0x01000000U
#define FLAG_FORCE          0x02000000U
#define FLAG_INSTALLED      0x04000000U
#define FLAG_REQUESTED      0x08000000U
#define FLAG_REQUIRED       0x10000000U
#define FLAG_UPGRADE        0x20000000U
#define FLAG_RESERVED       0x40000000U
#define FLAG_NO_HEADER_FREE 0x80000000U

#define FLAG_ID_MAX     0x00fffffe
#define FLAG_ID_INVALID 0x00ffffff

#define FILENAME_TAG 1000000
#define FILESIZE_TAG 1000001

#define FILTER_MODE_ALL_FILES     0
#define FILTER_MODE_UPGRADE_FILES 1
#define FILTER_MODE_CONF_FILES    2


static void
get_fullname_parts(URPM__Package pkg, char **name, char **version, char **release, char **arch, char **eos) {
  char *_version = NULL, *_release = NULL, *_arch = NULL, *_eos = NULL;

  if ((_eos = strchr(pkg->info, '@')) != NULL) {
    *_eos = 0; /* mark end of string to enable searching backwards */
    if ((_arch = strrchr(pkg->info, '.')) != NULL) {
      *_arch = 0;
      if ((release != NULL || version != NULL || name != NULL) && (_release = strrchr(pkg->info, '-')) != NULL) {
	*_release = 0;
	if ((version != NULL || name != NULL) && (_version = strrchr(pkg->info, '-')) != NULL) {
	  if (name != NULL) *name = pkg->info;
	  if (version != NULL) *version = _version + 1;
	}
	if (release != NULL) *release = _release + 1;
	*_release = '-';
      }
      if (arch != NULL) *arch = _arch + 1;
      *_arch = '.';
    }
    if (eos != NULL) *eos = _eos;
    *_eos = '@';
  }
}

static char *
get_name(Header header, int_32 tag) {
  int_32 type, count;
  char *name;

  headerGetEntry(header, tag, &type, (void **) &name, &count);
  return name;
}

static int
get_int(Header header, int_32 tag) {
  int_32 type, count;
  int *i;

  headerGetEntry(header, tag, &type, (void **) &i, &count);
  return i ? *i : 0;
}

static int
print_list_entry(char *buff, int sz, char *name, int_32 flags, char *evr) {
  int len = strlen(name);
  char *p = buff;

  if (len >= sz || !strncmp(name, "rpmlib(", 7)) return -1;
  memcpy(p, name, len); p += len;

  if (flags & RPMSENSE_PREREQ) {
    if (p - buff + 3 >= sz) return -1;
    memcpy(p, "[*]", 4); p += 3;
  }
  if (evr != NULL) {
    len = strlen(evr);
    if (len > 0) {
      if (p - buff + 6 + len >= sz) return -1;
      *p++ = '[';
      if (flags & RPMSENSE_LESS) *p++ = '<';
      if (flags & RPMSENSE_GREATER) *p++ = '>';
      if (flags & RPMSENSE_EQUAL) *p++ = '=';
      if ((flags & (RPMSENSE_LESS|RPMSENSE_EQUAL|RPMSENSE_GREATER)) == RPMSENSE_EQUAL) *p++ = '=';
      *p++ = ' ';
      memcpy(p, evr, len); p+= len;
      *p++ = ']';
    }
  }
  *p = 0; /* make sure to mark null char, Is it really necessary ? */

  return p - buff;
}

/* hacked to allow function outside XS code part to return object on perl stack,
   the function return SP which must be set to caller SP */
static SV **
xreturn_list_str(register SV **sp, char *s, Header header, int_32 tag_name, int_32 tag_flags, int_32 tag_version) {
  if (s != NULL) {
    char *ps = strchr(s, '@');
    if (tag_flags && tag_version) {
      while(ps != NULL) {
	XPUSHs(sv_2mortal(newSVpv(s, ps-s)));
	s = ps + 1; ps = strchr(s, '@');
      }
      XPUSHs(sv_2mortal(newSVpv(s, 0)));
    } else {
      char *eos;
      while(ps != NULL) {
	*ps = 0; eos = strchr(s, '['); if (!eos) eos = strchr(s, ' ');
	XPUSHs(sv_2mortal(newSVpv(s, eos ? eos-s : ps-s)));
	*ps = '@'; /* restore in memory modified char */
	s = ps + 1; ps = strchr(s, '@');
      }
      eos = strchr(s, '['); if (!eos) eos = strchr(s, ' ');
      XPUSHs(sv_2mortal(newSVpv(s, eos ? eos-s : 0)));
    }
  } else if (header) {
    char buff[4096];
    int_32 type, count;
    char **list = NULL;
    int_32 *flags = NULL;
    char **list_evr = NULL;
    int i;

    headerGetEntry(header, tag_name, &type, (void **) &list, &count);
    if (list) {
      if (tag_flags) headerGetEntry(header, tag_flags, &type, (void **) &flags, &count);
      if (tag_version) headerGetEntry(header, tag_version, &type, (void **) &list_evr, &count);
      for(i = 0; i < count; i++) {
	int len = print_list_entry(buff, sizeof(buff)-1, list[i], flags ? flags[i] : 0, list_evr ? list_evr[i] : NULL);
	if (len < 0) continue;
	XPUSHs(sv_2mortal(newSVpv(buff, len)));
      }

      free(list);
      free(list_evr);
    }
  }
  return sp;
}

static SV **
xreturn_list_int_32(register SV **sp, Header header, int_32 tag_name) {
  if (header) {
    int_32 type, count;
    int_32 *list = NULL;
    int i;

    headerGetEntry(header, tag_name, &type, (void **) &list, &count);
    if (list) {
      for(i = 0; i < count; i++) {
	XPUSHs(sv_2mortal(newSViv(list[i])));
      }
    }
  }
  return sp;
}

static SV **
xreturn_list_uint_16(register SV **sp, Header header, int_32 tag_name) {
  if (header) {
    int_32 type, count;
    uint_16 *list = NULL;
    int i;

    headerGetEntry(header, tag_name, &type, (void **) &list, &count);
    if (list) {
      for(i = 0; i < count; i++) {
	XPUSHs(sv_2mortal(newSViv(list[i])));
      }
    }
  }
  return sp;
}

static SV **
xreturn_files(register SV **sp, Header header, int filter_mode) {
  if (header) {
    char buff[4096];
    char *p, *s;
    STRLEN len;
    int_32 type, count;
    char **list = NULL;
    char **baseNames = NULL;
    char **dirNames = NULL;
    int_32 *dirIndexes = NULL;
    int_32 *flags = NULL;
    uint_16 *fmodes = NULL;
    int i;

    if (filter_mode) {
      headerGetEntry(header, RPMTAG_FILEFLAGS, &type, (void **) &flags, &count);
      headerGetEntry(header, RPMTAG_FILEMODES, &type, (void **) &fmodes, &count);
    }

    headerGetEntry(header, RPMTAG_BASENAMES, &type, (void **) &baseNames, &count);
    headerGetEntry(header, RPMTAG_DIRINDEXES, &type, (void **) &dirIndexes, NULL);
    headerGetEntry(header, RPMTAG_DIRNAMES, &type, (void **) &dirNames, NULL);
    if (!baseNames || !dirNames || !dirIndexes) {
      headerGetEntry(header, RPMTAG_OLDFILENAMES, &type, (void **) &list, &count);
      if (!list) return sp;
    }

    for(i = 0; i < count; i++) {
      if (list) {
	s = list[i];
	len = strlen(list[i]);
      } else {
	len = strlen(dirNames[dirIndexes[i]]);
	if (len >= sizeof(buff)) continue;
	memcpy(p = buff, dirNames[dirIndexes[i]], len + 1); p += len;
	len = strlen(baseNames[i]);
	if (p - buff + len >= sizeof(buff)) continue;
	memcpy(p, baseNames[i], len + 1); p += len;
	s = buff;
	len = p-buff;
      }

      if (filter_mode) {
	if ((filter_mode & FILTER_MODE_CONF_FILES) && flags && (flags[i] & RPMFILE_CONFIG) == 0) continue;
	if ((filter_mode & FILTER_MODE_UPGRADE_FILES) && fmodes &&
	    (S_ISDIR(fmodes[i]) || S_ISLNK(fmodes[i]) ||
	     !strncmp(s, "/dev", 4) || !strncmp(s, "/etc/rc.d", 9) ||
	     len >= 3 && !strncmp(s+len-3, ".la", 3))) continue;
      }

      XPUSHs(sv_2mortal(newSVpv(s, len)));
    }

    free(baseNames);
    free(dirNames);
    free(list);
  }
  return sp;
}

static char *
pack_list(Header header, int_32 tag_name, int_32 tag_flags, int_32 tag_version) {
  char buff[65536];
  int_32 type, count;
  char **list = NULL;
  int_32 *flags = NULL;
  char **list_evr = NULL;
  int i;
  char *p = buff;

  headerGetEntry(header, tag_name, &type, (void **) &list, &count);
  if (list) {
    if (tag_flags) headerGetEntry(header, tag_flags, &type, (void **) &flags, &count);
    if (tag_version) headerGetEntry(header, tag_version, &type, (void **) &list_evr, &count);
    for(i = 0; i < count; i++) {
      int len = print_list_entry(p, sizeof(buff)-(p-buff)-1, list[i], flags ? flags[i] : 0, list_evr ? list_evr[i] : NULL);
      if (len < 0) continue;
      p += len;
      *p++ = '@';
    }
    if (p > buff) p[-1] = 0;

    free(list);
    free(list_evr);
  }

  return p > buff ? memcpy(malloc(p-buff), buff, p-buff) : NULL;
}

static void
pack_header(URPM__Package pkg) {
  if (pkg->h) {
    if (pkg->info == NULL) {
      char buff[1024];
      char *p = buff;
      char *name = get_name(pkg->h, RPMTAG_NAME);
      char *version = get_name(pkg->h, RPMTAG_VERSION);
      char *release = get_name(pkg->h, RPMTAG_RELEASE);
      char *arch = headerIsEntry(pkg->h, RPMTAG_SOURCEPACKAGE) ? "src" : get_name(pkg->h, RPMTAG_ARCH);
      char *filename = get_name(pkg->h, FILENAME_TAG);

      p += snprintf(buff, sizeof(buff), "%s-%s-%s.%s@%d@%d@%s@", name, version, release, arch,
		    get_int(pkg->h, RPMTAG_EPOCH), get_int(pkg->h, RPMTAG_SIZE), get_name(pkg->h, RPMTAG_GROUP));
      if (filename) snprintf(p, sizeof(buff) - (p-buff), "%s-%s-%s.%s.rpm", name, version, release, arch);
      if (!filename || !strcmp(p, filename)) {
	p[-1] = 0;
      } else {
	p = p + snprintf(p, sizeof(buff) - (p-buff), "%s", filename);
      }
      pkg->info = memcpy(malloc(p-buff), buff, p-buff);
    }
    if (pkg->requires == NULL)
      pkg->requires = pack_list(pkg->h, RPMTAG_REQUIRENAME, RPMTAG_REQUIREFLAGS, RPMTAG_REQUIREVERSION);
    if (pkg->obsoletes == NULL)
      pkg->obsoletes = pack_list(pkg->h, RPMTAG_OBSOLETENAME, RPMTAG_OBSOLETEFLAGS, RPMTAG_OBSOLETEVERSION);
    if (pkg->conflicts == NULL)
      pkg->conflicts = pack_list(pkg->h, RPMTAG_CONFLICTNAME, RPMTAG_CONFLICTFLAGS, RPMTAG_CONFLICTVERSION);
    if (pkg->provides == NULL)
      pkg->provides = pack_list(pkg->h, RPMTAG_PROVIDENAME, RPMTAG_PROVIDEFLAGS, RPMTAG_PROVIDEVERSION);

    if (!(pkg->flag & FLAG_NO_HEADER_FREE)) headerFree(pkg->h);
    pkg->h = 0;
  }
}

static void
update_provide_entry(char *name, STRLEN len, int force, URPM__Package pkg, HV *provides) {
  SV** isv;

  if (!len) len = strlen(name);
  if ((isv = hv_fetch(provides, name, len, force))) {
    /* check if an entry has been found or created, it should so be updated */
    if (isv && !SvROK(*isv) || SvTYPE(SvRV(*isv)) != SVt_PVHV) {
      SV* choice_set = (SV*)newHV();
      if (choice_set) {
	SvREFCNT_dec(*isv); /* drop the old as we are changing it */
	if (!(*isv = newRV_noinc(choice_set))) {
	  SvREFCNT_dec(choice_set);
	  *isv = &PL_sv_undef;
	}
      }
    }
    if (isv && *isv != &PL_sv_undef) {
      char id[8];
      STRLEN id_len = snprintf(id, sizeof(id), "%d", pkg->flag & FLAG_ID);
      hv_fetch((HV*)SvRV(*isv), id, id_len, 1);
    }
  }
}

static void
update_provides(URPM__Package pkg, HV *provides) {
  if (pkg->h) {
    /* char buff[4096];
       int_32 *flags = NULL;
       char **list_evr = NULL; */
    char *p;
    int len;
    int_32 type, count;
    char **list = NULL;
    int i;

    /* examine requires for files which need to be marked in provides */
    headerGetEntry(pkg->h, RPMTAG_REQUIRENAME, &type, (void **) &list, &count);
    if (list) {
      for (i = 0; i < count; ++i) {
	len = strlen(list[i]);
	if (!strncmp(list[i], "rpmlib(", 7)) continue;
	if (list[i][0] == '/') hv_fetch(provides, list[i], len, 1);
      }
    }

    /* update all provides */
    /* headerGetEntry(pkg->h, RPMTAG_PROVIDEVERSION, &type, (void **) &list_evr, &count);
       headerGetEntry(pkg->h, RPMTAG_PROVIDEFLAGS, &type, (void **) &flags, &count); */
    headerGetEntry(pkg->h, RPMTAG_PROVIDENAME, &type, (void **) &list, &count);
    if (list) {
      for (i = 0; i < count; ++i) {
	len = strlen(list[i]);
	if (!strncmp(list[i], "rpmlib(", 7)) continue;
	update_provide_entry(list[i], len, 1, pkg, provides);
      }
    }
  } else {
    char *ps, *s;

    if ((s = pkg->requires) != NULL && *s != 0) {
      ps = strchr(s, '@');
      while(ps != NULL) {
	if (s[0] == '/') hv_fetch(provides, s, ps-s, 1);
	s = ps + 1; ps = strchr(s, '@');
      }
      if (s[0] == '/') hv_fetch(provides, s, strlen(s), 1);
    }

    if ((s = pkg->provides) != NULL && *s != 0) {
      char *es;

      ps = strchr(s, '@');
      while(ps != NULL) {
	*ps = 0; es = strchr(s, '['); if (!es) es = strchr(s, ' '); *ps = '@';
	update_provide_entry(s, es != NULL ? es-s : ps-s, 1, pkg, provides);
	s = ps + 1; ps = strchr(s, '@');
      }
      es = strchr(s, '['); if (!es) es = strchr(s, ' ');
      update_provide_entry(s, es != NULL ? es-s : 0, 1, pkg, provides);
    }
  }
}

static void
update_provides_files(URPM__Package pkg, HV *provides) {
  if (pkg->h) {
    STRLEN len;
    int_32 type, count;
    char **list = NULL;
    char **baseNames = NULL;
    char **dirNames = NULL;
    int_32 *dirIndexes = NULL;
    int i;

    headerGetEntry(pkg->h, RPMTAG_BASENAMES, &type, (void **) &baseNames, &count);
    headerGetEntry(pkg->h, RPMTAG_DIRINDEXES, &type, (void **) &dirIndexes, NULL);
    headerGetEntry(pkg->h, RPMTAG_DIRNAMES, &type, (void **) &dirNames, NULL);
    if (baseNames && dirNames && dirIndexes) {
      char buff[4096];
      char *p;

      for(i = 0; i < count; i++) {
	SV** isv;

	len = strlen(dirNames[dirIndexes[i]]);
	if (len >= sizeof(buff)) continue;
	memcpy(p = buff, dirNames[dirIndexes[i]], len + 1); p += len;
	len = strlen(baseNames[i]);
	if (p - buff + len >= sizeof(buff)) continue;
	memcpy(p, baseNames[i], len + 1); p += len;

	update_provide_entry(buff, p-buff, 0, pkg, provides);
      }

      free(baseNames);
      free(dirNames);
    } else {
      headerGetEntry(pkg->h, RPMTAG_OLDFILENAMES, &type, (void **) &list, &count);
      if (list) {
	for (i = 0; i < count; i++) {
	  len = strlen(list[i]);

	  update_provide_entry(list[i], len, 0, pkg, provides);
	}

	free(list);
      }
    }
  }
}

int
open_archive(char *filename, pid_t *pid) {
  int fd;
  struct {
    char header[4];
    char toc_d_count[4];
    char toc_l_count[4];
    char toc_f_count[4];
    char toc_str_size[4];
    char uncompress[40];
    char trailer[4];
  } buf;

  fd = open(filename, O_RDONLY);
  if (fd >= 0) {
    lseek(fd, -(int)sizeof(buf), SEEK_END);
    if (read(fd, &buf, sizeof(buf)) != sizeof(buf) || strncmp(buf.header, "cz[0", 4) || strncmp(buf.trailer, "0]cz", 4)) {
      /* this is not an archive, open it without magic, but first rewind at begin of file */
      lseek(fd, 0, SEEK_SET);
    } else {
      /* this is an archive, create a pipe and fork for reading with uncompress defined inside */
      int fdno[2];

      if (!pipe(fdno)) {
	if ((*pid = fork()) != 0) {
	  fd_set readfds;
	  struct timeval timeout;

	  FD_ZERO(&readfds);
	  FD_SET(fdno[0], &readfds);
	  timeout.tv_sec = 1;
	  timeout.tv_usec = 0;
	  select(fdno[0]+1, &readfds, NULL, NULL, &timeout);

	  close(fd);
	  fd = fdno[0];
	  close(fdno[1]);
	} else {
	  char *unpacker[22]; /* enough for 40 bytes in uncompress to never overbuf */
	  char *p = buf.uncompress;
	  int ip = 0;
	  char *ld_loader = getenv("LD_LOADER");

	  if (ld_loader && *ld_loader) {
	    unpacker[ip++] = ld_loader;
	  }

	  buf.trailer[0] = 0; /* make sure end-of-string is right */
	  while (*p) {
	    if (*p == ' ' || *p == '\t') *p++ = 0;
	    else {
	      unpacker[ip++] = p;
	      while (*p && *p != ' ' && *p != '\t') ++p;
	    }
	  }
	  unpacker[ip] = NULL; /* needed for execlp */

	  lseek(fd, 0, SEEK_SET);
	  dup2(fd, STDIN_FILENO); close(fd);
	  dup2(fdno[1], STDOUT_FILENO); close(fdno[1]);
	  fd = open("/dev/null", O_WRONLY);
	  dup2(fd, STDERR_FILENO); close(fd);
	  execvp(unpacker[0], unpacker);
	  exit(1);
	}
      } else {
	close(fd);
	fd = -1;
      }
    }
  }
  return fd;
}

static void
parse_line(AV *depslist, HV *provides, URPM__Package pkg, char *buff) {
  char *tag, *data;
  int data_len;

  if ((tag = strchr(buff, '@')) != NULL && (data = strchr(tag+1, '@')) != NULL) {
    *tag++ = *data++ = 0;
    data_len = 1+strlen(data);
    if (!strcmp(tag, "info")) {
      pkg->info = memcpy(malloc(data_len), data, data_len);
      pkg->flag &= ~FLAG_ID;
      pkg->flag |= 1 + av_len(depslist);
      if (provides) update_provides(pkg, provides);
      av_push(depslist, sv_setref_pv(newSVpv("", 0), "URPM::Package",
				     memcpy(malloc(sizeof(struct s_Package)), pkg, sizeof(struct s_Package))));
      memset(pkg, 0, sizeof(struct s_Package));
    } else if (!strcmp(tag, "requires")) {
      free(pkg->requires); pkg->requires = memcpy(malloc(data_len), data, data_len);
    } else if (!strcmp(tag, "obsoletes")) {
      free(pkg->obsoletes); pkg->obsoletes = memcpy(malloc(data_len), data, data_len);
    } else if (!strcmp(tag, "conflicts")) {
      free(pkg->conflicts); pkg->conflicts = memcpy(malloc(data_len), data, data_len);
    } else if (!strcmp(tag, "provides")) {
      free(pkg->provides); pkg->provides = memcpy(malloc(data_len), data, data_len);
    }
  }
}

static void
read_config_files() {
  static int already = 0;

  if (!already) {
    rpmReadConfigFiles(NULL, NULL);
    already = 1;
  }
}

static void callback_empty(void) {}

MODULE = URPM            PACKAGE = URPM::Package       PREFIX = Pkg_

void
Pkg_DESTROY(pkg)
  URPM::Package pkg
  CODE:
  free(pkg->info);
  free(pkg->requires);
  free(pkg->obsoletes);
  free(pkg->conflicts);
  free(pkg->provides);
  free(pkg->rates);
  if (pkg->h && !(pkg->flag & FLAG_NO_HEADER_FREE)) headerFree(pkg->h);
  free(pkg);

void
Pkg_name(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->info) {
    char *name;
    char *version;

    get_fullname_parts(pkg, &name, &version, NULL, NULL, NULL);
    XPUSHs(sv_2mortal(newSVpv(name, version-name-1)));
  } else if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(get_name(pkg->h, RPMTAG_NAME), 0)));
  }

void
Pkg_version(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->info) {
    char *version;
    char *release;

    get_fullname_parts(pkg, NULL, &version, &release, NULL, NULL);
    XPUSHs(sv_2mortal(newSVpv(version, release-version-1)));
  } else if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(get_name(pkg->h, RPMTAG_VERSION), 0)));
  }

void
Pkg_release(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->info) {
    char *release;
    char *arch;

    get_fullname_parts(pkg, NULL, NULL, &release, &arch, NULL);
    XPUSHs(sv_2mortal(newSVpv(release, arch-release-1)));
  } else if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(get_name(pkg->h, RPMTAG_RELEASE), 0)));
  }

void
Pkg_arch(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->info) {
    char *arch;
    char *eos;

    get_fullname_parts(pkg, NULL, NULL, NULL, &arch, &eos);
    XPUSHs(sv_2mortal(newSVpv(arch, eos-arch)));
  } else if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(headerIsEntry(pkg->h, RPMTAG_SOURCEPACKAGE) ? "src" : get_name(pkg->h, RPMTAG_ARCH), 0)));
  }

int
Pkg_is_arch_compat(pkg)
  URPM::Package pkg
  CODE:
  read_config_files();
  if (pkg->info) {
    char *arch;
    char *eos;

    get_fullname_parts(pkg, NULL, NULL, NULL, &arch, &eos);
    *eos = 0;
    RETVAL = rpmMachineScore(RPM_MACHTABLE_INSTARCH, arch);
    *eos = '@';
  } else if (pkg->h && !headerIsEntry(pkg->h, RPMTAG_SOURCEPACKAGE)) {
    RETVAL = rpmMachineScore(RPM_MACHTABLE_INSTARCH, get_name(pkg->h, RPMTAG_ARCH));
  } else {
    RETVAL = 0;
  }
  OUTPUT:
  RETVAL

void
Pkg_summary(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(get_name(pkg->h, RPMTAG_SUMMARY), 0)));
  }

void
Pkg_description(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(get_name(pkg->h, RPMTAG_DESCRIPTION), 0)));
  }

void
Pkg_sourcerpm(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(get_name(pkg->h, RPMTAG_SOURCERPM), 0)));
  }

void
Pkg_fullname(pkg)
  URPM::Package pkg
  PREINIT:
  I32 gimme = GIMME_V;
  PPCODE:
  if (pkg->info) {
    if (gimme == G_SCALAR) {
      char *eos;
      if ((eos = strchr(pkg->info, '@')) != NULL) {
	XPUSHs(sv_2mortal(newSVpv(pkg->info, eos-pkg->info)));
      }
    } else if (gimme == G_ARRAY) {
      char *name, *version, *release, *arch, *eos;
      get_fullname_parts(pkg, &name, &version, &release, &arch, &eos);
      EXTEND(SP, 4);
      PUSHs(sv_2mortal(newSVpv(name, version-name-1)));
      PUSHs(sv_2mortal(newSVpv(version, release-version-1)));
      PUSHs(sv_2mortal(newSVpv(release, arch-release-1)));
      PUSHs(sv_2mortal(newSVpv(arch, eos-arch)));
    }
  } else if (pkg->h) {
    char *name = get_name(pkg->h, RPMTAG_NAME);
    char *version = get_name(pkg->h, RPMTAG_VERSION);
    char *release = get_name(pkg->h, RPMTAG_RELEASE);
    char *arch = headerIsEntry(pkg->h, RPMTAG_SOURCEPACKAGE) ? "src" : get_name(pkg->h, RPMTAG_ARCH);

    if (gimme == G_SCALAR) {
      XPUSHs(sv_2mortal(newSVpvf("%s-%s-%s.%s", name, version, release, arch)));
    } else if (gimme == G_ARRAY) {
      EXTEND(SP, 4);
      PUSHs(sv_2mortal(newSVpv(name, 0)));
      PUSHs(sv_2mortal(newSVpv(version, 0)));
      PUSHs(sv_2mortal(newSVpv(release, 0)));
      PUSHs(sv_2mortal(newSVpv(arch, 0)));
    }
  }

int
Pkg_epoch(pkg)
  URPM::Package pkg
  CODE:
  if (pkg->info) {
    char *s, *eos;

    if ((s = strchr(pkg->info, '@')) != NULL) {
      if ((eos = strchr(s+1, '@')) != NULL) *eos = 0; /* mark end of string to enable searching backwards */
      RETVAL = atoi(s+1);
      if (eos != NULL) *eos = '@';
    } else {
      RETVAL = 0;
    }
  } else if (pkg->h) {
    RETVAL = get_int(pkg->h, RPMTAG_SERIAL);
  } else RETVAL = 0;
  OUTPUT:
  RETVAL

int
Pkg_compare_pkg(lpkg, rpkg)
  URPM::Package lpkg
  URPM::Package rpkg
  PREINIT:
  int compare = 0;
  int lepoch;
  char *lversion;
  char *lrelease;
  char *larch;
  char *leos;
  int repoch;
  char *rversion;
  char *rrelease;
  char *rarch;
  char *reos;
  CODE:
  if (lpkg->info) {
    char *s;

    if ((s = strchr(lpkg->info, '@')) != NULL) {
      if ((leos = strchr(s+1, '@')) != NULL) *leos = 0; /* mark end of string to enable searching backwards */
      lepoch = atoi(s+1);
      if (leos != NULL) *leos = '@';
    } else {
      lepoch = 0;
    }
    get_fullname_parts(lpkg, NULL, &lversion, &lrelease, &larch, &leos);
    /* temporaly mark end of each substring */
    lrelease[-1] = 0;
    larch[-1] = 0;
  } else if (lpkg->h) {
    lepoch = get_int(lpkg->h, RPMTAG_EPOCH);
    lversion = get_name(lpkg->h, RPMTAG_VERSION);
    lrelease = get_name(lpkg->h, RPMTAG_RELEASE);
    larch = headerIsEntry(lpkg->h, RPMTAG_SOURCEPACKAGE) ? "src" : get_name(lpkg->h, RPMTAG_ARCH);
  } else croak("undefined package");
  if (rpkg->info) {
    char *s;

    if ((s = strchr(rpkg->info, '@')) != NULL) {
      if ((reos = strchr(s+1, '@')) != NULL) *reos = 0; /* mark end of string to enable searching backwards */
      repoch = atoi(s+1);
      if (reos != NULL) *reos = '@';
    } else {
      repoch = 0;
    }
    get_fullname_parts(rpkg, NULL, &rversion, &rrelease, &rarch, &reos);
    /* temporaly mark end of each substring */
    rrelease[-1] = 0;
    rarch[-1] = 0;
  } else if (rpkg->h) {
    repoch = get_int(rpkg->h, RPMTAG_EPOCH);
    rversion = get_name(rpkg->h, RPMTAG_VERSION);
    rrelease = get_name(rpkg->h, RPMTAG_RELEASE);
    rarch = headerIsEntry(rpkg->h, RPMTAG_SOURCEPACKAGE) ? "src" : get_name(rpkg->h, RPMTAG_ARCH);
  } else {
    /* restore info string modified */
    if (lpkg->info) {
      lrelease[-1] = '-';
      larch[-1] = '.';
    }
    croak("undefined package");
  }
  compare = lepoch - repoch;
  if (!compare) {
    compare = rpmvercmp(lversion, rversion);
    if (!compare) {
      compare = rpmvercmp(lrelease, rrelease);
      if (!compare) {
	int lscore, rscore;

	read_config_files();
	lscore = rpmMachineScore(RPM_MACHTABLE_INSTARCH, larch);
	rscore = rpmMachineScore(RPM_MACHTABLE_INSTARCH, rarch);
	if (lscore == 0) {
	  if (rscore == 0)
	    compare = strcmp(larch, rarch);
	  else
	    compare = -1;
	} else {
	  if (rscore == 0)
	    compare = 1;
	  else
	    compare = rscore - lscore; /* score are lower for better */
	}
      }
    }
  }
  /* restore info string modified */
  if (lpkg->info) {
    lrelease[-1] = '-';
    larch[-1] = '.';
  }
  if (rpkg->info) {
    rrelease[-1] = '-';
    rarch[-1] = '.';
  }
  RETVAL = compare;
  OUTPUT:
  RETVAL

int
Pkg_compare(pkg, evr)
  URPM::Package pkg
  char *evr
  PREINIT:
  int compare = 0;
  int _epoch;
  char *_version;
  char *_release;
  char *_eos;
  CODE:
  if (pkg->info) {
    char *s;

    if ((s = strchr(pkg->info, '@')) != NULL) {
      if ((_eos = strchr(s+1, '@')) != NULL) *_eos = 0; /* mark end of string to enable searching backwards */
      _epoch = atoi(s+1);
      if (_eos != NULL) *_eos = '@';
    } else {
      _epoch = 0;
    }
    get_fullname_parts(pkg, NULL, &_version, &_release, &_eos, NULL);
    /* temporaly mark end of each substring */
    _release[-1] = 0;
    _eos[-1] = 0;
  } else if (pkg->h) {
    _epoch = get_int(pkg->h, RPMTAG_EPOCH);
  } else croak("undefined package");
  if (!compare) {
    char *epoch, *version, *release;

    /* extract epoch and version from evr */
    version = evr;
    while (*version && isdigit(*version)) version++;
    if (*version == ':') {
      epoch = evr;
      *version++ = 0;
      if (!*epoch) epoch = "0";
      compare = _epoch - (*epoch ? atoi(epoch) : 0);
      version[-1] = ':'; /* restore in memory modification */
    } else {
      /* there is no epoch defined, so no check on epoch and assume equality */
      version = evr;
    }
    if (!compare) {
      if (!pkg->info)
	_version = get_name(pkg->h, RPMTAG_VERSION);
      /* continue extracting release if any */
      if ((release = strrchr(version, '-')) != NULL) {
	*release++ = 0;
	compare = rpmvercmp(_version, version);
	if (!compare) {
	  /* need to compare with release here */
	  if (!pkg->info)
	    _release = get_name(pkg->h, RPMTAG_RELEASE);
	  compare = rpmvercmp(_release, release);
	}
	release[-1] = '-'; /* restore in memory modification */
      } else {
	compare = rpmvercmp(_version, version);
      }
    }
  }
  /* restore info string modified */
  if (pkg->info) {
    _release[-1] = '-';
    _eos[-1] = '.';
  }
  RETVAL = compare;
  OUTPUT:
  RETVAL

int
Pkg_size(pkg)
  URPM::Package pkg
  CODE:
  if (pkg->info) {
    char *s, *eos;

    if ((s = strchr(pkg->info, '@')) != NULL && (s = strchr(s+1, '@')) != NULL) {
      if ((eos = strchr(s+1, '@')) != NULL) *eos = 0; /* mark end of string to enable searching backwards */
      RETVAL = atoi(s+1);
      if (eos != NULL) *eos = '@';
    } else {
      RETVAL = 0;
    }
  } else if (pkg->h) {
    RETVAL = get_int(pkg->h, RPMTAG_SIZE);
  } else RETVAL = 0;
  OUTPUT:
  RETVAL

void
Pkg_group(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->info) {
    char *s;

    if ((s = strchr(pkg->info, '@')) != NULL && (s = strchr(s+1, '@')) != NULL && (s = strchr(s+1, '@')) != NULL) {
      char *eos = strchr(s+1, '@');
      XPUSHs(sv_2mortal(newSVpv(s+1, eos != NULL ? eos-s-1 : 0)));
    }
  } else if (pkg->h) {
    XPUSHs(sv_2mortal(newSVpv(get_name(pkg->h, RPMTAG_GROUP), 0)));
  }

void
Pkg_filename(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->info) {
    char *s, *eon, *eos;

    if ((eon = strchr(pkg->info, '@')) != NULL) {
      if ((s = strchr(eon+1, '@')) != NULL && (s = strchr(s+1, '@')) != NULL && (s = strchr(s+1, '@')) != NULL) {
	eos = strchr(s+1, '@');
	XPUSHs(sv_2mortal(newSVpv(s+1, eos != NULL ? eos-s-1 : 0)));
      } else {
	char savbuf[4];
	memcpy(savbuf, eon, 4); /* there should be at least epoch and size described so (@0@0 minimum) */
	memcpy(eon, ".rpm", 4);
	XPUSHs(sv_2mortal(newSVpv(pkg->info, eon-pkg->info+4)));
	memcpy(eon, savbuf, 4);
      }
    }
  } else if (pkg->h) {
    char *filename = get_name(pkg->h, FILENAME_TAG);

    if (filename != NULL)
      XPUSHs(sv_2mortal(newSVpv(filename, 0)));
  }

void
Pkg_id(pkg)
  URPM::Package pkg
  PPCODE:
  if ((pkg->flag & FLAG_ID) <= FLAG_ID_MAX) {
    XPUSHs(sv_2mortal(newSViv(pkg->flag & FLAG_ID)));
  }

void
Pkg_set_id(pkg, id=-1)
  URPM::Package pkg
  int id
  PPCODE:
  if ((pkg->flag & FLAG_ID) <= FLAG_ID_MAX) {
    XPUSHs(sv_2mortal(newSViv(pkg->flag & FLAG_ID)));
  }
  pkg->flag &= ~FLAG_ID;
  pkg->flag |= id >= 0 && id <= FLAG_ID_MAX ? id : FLAG_ID_INVALID;

void
Pkg_requires(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->requires, pkg->h, RPMTAG_REQUIRENAME, RPMTAG_REQUIREFLAGS, RPMTAG_REQUIREVERSION);

void
Pkg_requires_nosense(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->requires, pkg->h, RPMTAG_REQUIRENAME, 0, 0);

void
Pkg_obsoletes(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->obsoletes, pkg->h, RPMTAG_OBSOLETENAME, RPMTAG_OBSOLETEFLAGS, RPMTAG_OBSOLETEVERSION);

void
Pkg_obsoletes_nosense(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->obsoletes, pkg->h, RPMTAG_OBSOLETENAME, 0, 0);

void
Pkg_conflicts(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->conflicts, pkg->h, RPMTAG_CONFLICTNAME, RPMTAG_CONFLICTFLAGS, RPMTAG_CONFLICTVERSION);

void
Pkg_conflicts_nosense(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->conflicts, pkg->h, RPMTAG_CONFLICTNAME, 0, 0);

void
Pkg_provides(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->provides, pkg->h, RPMTAG_PROVIDENAME, RPMTAG_PROVIDEFLAGS, RPMTAG_PROVIDEVERSION);

void
Pkg_provides_nosense(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, pkg->provides, pkg->h, RPMTAG_PROVIDENAME, 0, 0);

void
Pkg_files(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_files(SP, pkg->h, 0);

void
Pkg_files_md5sum(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, NULL, pkg->h, RPMTAG_FILEMD5S, 0, 0);

void
Pkg_files_owner(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, NULL, pkg->h, RPMTAG_FILEUSERNAME, 0, 0);

void
Pkg_files_group(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, NULL, pkg->h, RPMTAG_FILEGROUPNAME, 0, 0);

void
Pkg_files_mtime(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_int_32(SP, pkg->h, RPMTAG_FILEMTIMES);

void
Pkg_files_size(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_int_32(SP, pkg->h, RPMTAG_FILESIZES);

void
Pkg_files_uid(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_int_32(SP, pkg->h, RPMTAG_FILEUIDS);

void
Pkg_files_gid(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_int_32(SP, pkg->h, RPMTAG_FILEGIDS);

void
Pkg_files_mode(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_uint_16(SP, pkg->h, RPMTAG_FILEMODES);

void
Pkg_conf_files(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_files(SP, pkg->h, FILTER_MODE_CONF_FILES);

void
Pkg_upgrade_files(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_files(SP, pkg->h, FILTER_MODE_UPGRADE_FILES);

void
Pkg_pack_header(pkg)
  URPM::Package pkg
  CODE:
  pack_header(pkg);

void
Pkg_build_info(pkg, fileno, provides_files=NULL)
  URPM::Package pkg
  int fileno
  char *provides_files
  CODE:
  if (pkg->info) {
    char buff[65536];
    int size;

    /* info line should be the last to be written */
    if (pkg->provides && *pkg->provides) {
      size = snprintf(buff, sizeof(buff), "@provides@%s\n", pkg->provides);
      if (size < sizeof(buff)) {
	if (provides_files && *provides_files) {
	  --size;
	  size += snprintf(buff+size, sizeof(buff)-size, "@%s\n", provides_files);
	}
	write(fileno, buff, size);
      }
    }
    if (pkg->conflicts && *pkg->conflicts) {
      size = snprintf(buff, sizeof(buff), "@conflicts@%s\n", pkg->conflicts);
      if (size < sizeof(buff)) write(fileno, buff, size);
    }
    if (pkg->obsoletes && *pkg->obsoletes) {
      size = snprintf(buff, sizeof(buff), "@obsoletes@%s\n", pkg->obsoletes);
      if (size < sizeof(buff)) write(fileno, buff, size);
    }
    if (pkg->requires && *pkg->requires) {
      size = snprintf(buff, sizeof(buff), "@requires@%s\n", pkg->requires);
      if (size < sizeof(buff)) write(fileno, buff, size);
    }
    size = snprintf(buff, sizeof(buff), "@info@%s\n", pkg->info);
    write(fileno, buff, size);
  } else croak("no info available for package");

void
Pkg_build_header(pkg, fileno)
  URPM::Package pkg
  int fileno
  CODE:
  if (pkg->h) {
    FD_t fd;

    fd = fdDup(fileno);
    headerWrite(fd, pkg->h, HEADER_MAGIC_YES);
    fdClose(fd);
  } else croak("no header available for package");

int
Pkg_flag_base(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_BASE;
  OUTPUT:
  RETVAL

int
Pkg_set_flag_base(pkg, value=1)
  URPM::Package pkg
  int value
  CODE:
  RETVAL = pkg->flag & FLAG_BASE;
  if (value) pkg->flag |= FLAG_BASE;
  else       pkg->flag &= ~FLAG_BASE;
  OUTPUT:
  RETVAL

int
Pkg_flag_force(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_FORCE;
  OUTPUT:
  RETVAL

int
Pkg_set_flag_force(pkg, value=1)
  URPM::Package pkg
  int value
  CODE:
  RETVAL = pkg->flag & FLAG_FORCE;
  if (value) pkg->flag |= FLAG_FORCE;
  else       pkg->flag &= ~FLAG_FORCE;
  OUTPUT:
  RETVAL

int
Pkg_flag_installed(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_INSTALLED;
  OUTPUT:
  RETVAL

int
Pkg_set_flag_installed(pkg, value=1)
  URPM::Package pkg
  int value
  CODE:
  RETVAL = pkg->flag & FLAG_INSTALLED;
  if (value) pkg->flag |= FLAG_INSTALLED;
  else       pkg->flag &= ~FLAG_INSTALLED;
  OUTPUT:
  RETVAL

int
Pkg_flag_requested(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_REQUESTED;
  OUTPUT:
  RETVAL

int
Pkg_set_flag_requested(pkg, value=1)
  URPM::Package pkg
  int value
  CODE:
  RETVAL = pkg->flag & FLAG_REQUESTED;
  if (value) pkg->flag |= FLAG_REQUESTED;
  else       pkg->flag &= ~FLAG_REQUESTED;
  OUTPUT:
  RETVAL

int
Pkg_flag_required(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_REQUIRED;
  OUTPUT:
  RETVAL

int
Pkg_set_flag_required(pkg, value=1)
  URPM::Package pkg
  int value
  CODE:
  RETVAL = pkg->flag & FLAG_REQUIRED;
  if (value) pkg->flag |= FLAG_REQUIRED;
  else       pkg->flag &= ~FLAG_REQUIRED;
  OUTPUT:
  RETVAL

int
Pkg_flag_upgrade(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_UPGRADE;
  OUTPUT:
  RETVAL

int
Pkg_set_flag_upgrade(pkg, value=1)
  URPM::Package pkg
  int value
  CODE:
  RETVAL = pkg->flag & FLAG_UPGRADE;
  if (value) pkg->flag |= FLAG_UPGRADE;
  else       pkg->flag &= ~FLAG_UPGRADE;
  OUTPUT:
  RETVAL


MODULE = URPM            PACKAGE = URPM::DB            PREFIX = Db_

URPM::DB
Db_open(prefix="/")
  char *prefix
  PREINIT:
  rpmdb db;
  rpmErrorCallBackType old_cb;
  CODE:
  read_config_files();
  old_cb = rpmErrorSetCallback(callback_empty);
  rpmSetVerbosity(RPMMESS_FATALERROR);
  RETVAL = rpmdbOpen(prefix, &db, O_RDONLY, 0644) == 0 ? db : NULL;
  rpmErrorSetCallback(old_cb);
  rpmSetVerbosity(RPMMESS_NORMAL);
  OUTPUT:
  RETVAL

URPM::DB
Db_open_rw(prefix="/")
  char *prefix
  PREINIT:
  rpmdb db;
  rpmErrorCallBackType old_cb;
  CODE:
  read_config_files();
  old_cb = rpmErrorSetCallback(callback_empty);
  rpmSetVerbosity(RPMMESS_FATALERROR);
  RETVAL = rpmdbOpen(prefix, &db, O_RDWR | O_CREAT, 0644) == 0 ? db : NULL;
  rpmErrorSetCallback(old_cb);
  rpmSetVerbosity(RPMMESS_NORMAL);
  OUTPUT:
  RETVAL

void
Db_DESTROY(db)
  URPM::DB db
  CODE:
  rpmdbClose(db);

int
Db_traverse(db,callback)
  URPM::DB db
  SV *callback
  PREINIT:
  Header header;
  rpmdbMatchIterator mi;
  int count = 0;
  CODE:
  mi = rpmdbInitIterator(db, RPMDBI_PACKAGES, NULL, 0);
  while (header = rpmdbNextIterator(mi)) {
    if (SvROK(callback)) {
      dSP;
      URPM__Package pkg = calloc(1, sizeof(struct s_Package));

      pkg->flag = FLAG_ID_INVALID | FLAG_NO_HEADER_FREE;
      pkg->h = header;

      ENTER;
      SAVETMPS;
      PUSHMARK(SP);
      XPUSHs(sv_2mortal(sv_setref_pv(newSVpv("", 0), "URPM::Package", pkg)));
      PUTBACK;

      call_sv(callback, G_DISCARD | G_SCALAR);
      pkg->h = 0; /* avoid using it anymore, in case it has been copied inside callback */

      FREETMPS;
      LEAVE;
    }
    ++count;
  }
  rpmdbFreeIterator(mi);
  RETVAL = count;
  OUTPUT:
  RETVAL

int
Db_traverse_tag(db,tag,names,callback)
  URPM::DB db
  char *tag
  SV *names
  SV *callback
  PREINIT:
  Header header;
  rpmdbMatchIterator mi;
  int count = 0;
  CODE:
  if (SvROK(names) && SvTYPE(SvRV(names)) == SVt_PVAV) {
    AV* names_av = (AV*)SvRV(names);
    int len = av_len(names_av);
    SV** isv;
    int i, rpmtag;

    if (!strcmp(tag, "name"))
      rpmtag = RPMTAG_NAME;
    else if (!strcmp(tag, "whatprovides"))
      rpmtag = RPMTAG_PROVIDENAME;
    else if (!strcmp(tag, "whatrequires"))
      rpmtag = RPMTAG_REQUIRENAME;
    else if (!strcmp(tag, "group"))
      rpmtag = RPMTAG_GROUP;
    else if (!strcmp(tag, "triggeredby"))
      rpmtag = RPMTAG_BASENAMES;
    else if (!strcmp(tag, "path"))
      rpmtag = RPMTAG_BASENAMES;
    else croak("unknown tag");

    for (i = 0; i <= len; ++i) {
      STRLEN str_len;
      SV **isv = av_fetch(names_av, i, 0);
      char *name = SvPV(*isv, str_len);

      mi = rpmdbInitIterator((rpmdb)db, rpmtag, name, str_len);
      while (header = rpmdbNextIterator(mi)) {
	if (SvROK(callback)) {
	  dSP;
	  URPM__Package pkg = calloc(1, sizeof(struct s_Package));

	  pkg->flag = FLAG_ID_INVALID | FLAG_NO_HEADER_FREE;
	  pkg->h = header;

	  ENTER;
	  SAVETMPS;
	  PUSHMARK(SP);
	  XPUSHs(sv_2mortal(sv_setref_pv(newSVpv("", 0), "URPM::Package", pkg)));
	  PUTBACK;

	  call_sv(callback, G_DISCARD | G_SCALAR);
	  pkg->h = 0; /* avoid using it anymore, in case it has been copied inside callback */

	  FREETMPS;
	  LEAVE;
	}
	++count;
      }
      rpmdbFreeIterator(mi);
    } 
  } else croak("bad arguments list");
  RETVAL = count;
  OUTPUT:
  RETVAL

MODULE = URPM            PACKAGE = URPM                PREFIX = Urpm_

void
Urpm_parse_synthesis(urpm, filename)
  SV *urpm
  char *filename
  PPCODE:
  if (SvROK(urpm) && SvTYPE(SvRV(urpm)) == SVt_PVHV) {
    SV **fdepslist = hv_fetch((HV*)SvRV(urpm), "depslist", 8, 0);
    AV *depslist = fdepslist && SvROK(*fdepslist) && SvTYPE(SvRV(*fdepslist)) == SVt_PVAV ? (AV*)SvRV(*fdepslist) : NULL;
    SV **fprovides = hv_fetch((HV*)SvRV(urpm), "provides", 8, 0);
    HV *provides = fprovides && SvROK(*fprovides) && SvTYPE(SvRV(*fprovides)) == SVt_PVHV ? (HV*)SvRV(*fprovides) : NULL;

    if (depslist != NULL) {
      char buff[65536];
      char *p, *eol;
      int buff_len;
      struct s_Package pkg;
      gzFile f;
      int start_id = 1 + av_len(depslist);
      int count = 1;

      if ((f = gzopen(filename, "rb")) != NULL) {
	memset(&pkg, 0, sizeof(struct s_Package));
	buff[sizeof(buff)-1] = 0;
	p = buff;
	while ((buff_len = gzread(f, p, sizeof(buff)-1-(p-buff)) + (p-buff)) != 0) {
	  p = buff;
	  if ((eol = strchr(p, '\n')) != NULL) {
	    do {
	      *eol++ = 0;
	      parse_line(depslist, provides, &pkg, p);
	      p = eol;
	    } while ((eol = strchr(p, '\n')) != NULL);
	  } else {
	    /* a line larger than sizeof(buff) has been encountered, bad file problably */
	    break;
	  }
	  if (gzeof(f)) {
	    parse_line(depslist, provides, &pkg, p);
	    break;
	  } else {
	    memmove(buff, p, buff_len-(p-buff));
	    p = &buff[buff_len-(p-buff)];
	  }
	}
	gzclose(f);
	if (av_len(depslist) >= start_id) {
	  XPUSHs(sv_2mortal(newSViv(start_id)));
	  XPUSHs(sv_2mortal(newSViv(av_len(depslist))));
	}
      } else croak("unable to uncompress synthesis file");
    } else croak("first argument should contains a depslist ARRAY reference");
  } else croak("first argument should be a reference to HASH");

void
Urpm_parse_hdlist(urpm, filename, packing=0)
  SV *urpm
  char *filename
  int packing
  PPCODE:
  if (SvROK(urpm) && SvTYPE(SvRV(urpm)) == SVt_PVHV) {
    SV **fdepslist = hv_fetch((HV*)SvRV(urpm), "depslist", 8, 0);
    AV *depslist = fdepslist && SvROK(*fdepslist) && SvTYPE(SvRV(*fdepslist)) == SVt_PVAV ? (AV*)SvRV(*fdepslist) : NULL;
    SV **fprovides = hv_fetch((HV*)SvRV(urpm), "provides", 8, 0);
    HV *provides = fprovides && SvROK(*fprovides) && SvTYPE(SvRV(*fprovides)) == SVt_PVHV ? (HV*)SvRV(*fprovides) : NULL;

    if (depslist != NULL) {
      pid_t pid;
      int d;
      FD_t fd;

      d = open_archive(filename, &pid);
      fd = fdDup(d);
      close(d);

      if (fdFileno(fd) >= 0) {
	Header header;
	int start_id = 1 + av_len(depslist);

	do {
	  int count = 4;
	  header=headerRead(fd, HEADER_MAGIC_YES);
	  while (header == NULL && count > 0) {
	    fd_set readfds;
	    struct timeval timeout;

	    FD_ZERO(&readfds);
	    FD_SET(fdFileno(fd), &readfds);
	    timeout.tv_sec = 1;
	    timeout.tv_usec = 0;
	    select(fdFileno(fd)+1, &readfds, NULL, NULL, &timeout);

	    header=headerRead(fd, HEADER_MAGIC_YES);
	    --count;
	  }
	  if (header != NULL) {
	    struct s_Package pkg;

	    memset(&pkg, 0, sizeof(struct s_Package));
	    pkg.flag = 1 + av_len(depslist);
	    pkg.h = header;
	    if (provides) {
	      update_provides(&pkg, provides);
	      update_provides_files(&pkg, provides);
	    }
	    if (packing) pack_header(&pkg);
	    av_push(depslist, sv_setref_pv(newSVpv("", 0), "URPM::Package",
					   memcpy(malloc(sizeof(struct s_Package)), &pkg, sizeof(struct s_Package))));
	  }
	} while (header != NULL);
	fdClose(fd);
	if (pid) {
	  kill(pid, SIGTERM);
	  waitpid(pid, NULL, 0);
	  pid = 0;
	}
	if (av_len(depslist) >= start_id) {
	  XPUSHs(sv_2mortal(newSViv(start_id)));
	  XPUSHs(sv_2mortal(newSViv(av_len(depslist))));
	}
      } else croak("cannot open hdlist file");
    } else croak("first argument should contains a depslist ARRAY reference");
  } else croak("first argument should be a reference to HASH");

void
Urpm_parse_rpm(urpm, filename, packing=0)
  SV *urpm
  char *filename
  int packing
  PPCODE:
  if (SvROK(urpm) && SvTYPE(SvRV(urpm)) == SVt_PVHV) {
    SV **fdepslist = hv_fetch((HV*)SvRV(urpm), "depslist", 8, 0);
    AV *depslist = fdepslist && SvROK(*fdepslist) && SvTYPE(SvRV(*fdepslist)) == SVt_PVAV ? (AV*)SvRV(*fdepslist) : NULL;
    SV **fprovides = hv_fetch((HV*)SvRV(urpm), "provides", 8, 0);
    HV *provides = fprovides && SvROK(*fprovides) && SvTYPE(SvRV(*fprovides)) == SVt_PVHV ? (HV*)SvRV(*fprovides) : NULL;

    if (depslist != NULL) {
      FD_t fd = fdOpen(filename, O_RDONLY, 0666);
      Header header;
      int isSource;

      if (fdFileno(fd) >= 0) {
	if (rpmReadPackageHeader(fd, &header, &isSource, NULL, NULL) == 0) {
	  struct s_Package pkg;
	  struct stat sb;
	  char *basename;
	  int_32 size;

	  basename = strrchr(filename, '/');
	  fstat(fdFileno(fd), &sb);
	  size = sb.st_size;
	  headerAddEntry(header, FILENAME_TAG, RPM_STRING_TYPE, basename != NULL ? basename + 1 : filename, 1);
	  headerAddEntry(header, FILESIZE_TAG, RPM_INT32_TYPE, &size, 1);

	  memset(&pkg, 0, sizeof(struct s_Package));
	  pkg.flag = 1 + av_len(depslist);
	  pkg.h = header;
	  if (provides) {
	    update_provides(&pkg, provides);
	    update_provides_files(&pkg, provides);
	  }
	  if (packing) pack_header(&pkg);
	  else {
	    headerRemoveEntry(pkg.h, RPMTAG_POSTIN);
	    headerRemoveEntry(pkg.h, RPMTAG_POSTUN);
	    headerRemoveEntry(pkg.h, RPMTAG_PREIN);
	    headerRemoveEntry(pkg.h, RPMTAG_PREUN);
	    headerRemoveEntry(pkg.h, RPMTAG_FILEUSERNAME);
	    headerRemoveEntry(pkg.h, RPMTAG_FILEGROUPNAME);
	    headerRemoveEntry(pkg.h, RPMTAG_FILEVERIFYFLAGS);
	    headerRemoveEntry(pkg.h, RPMTAG_FILERDEVS);
	    headerRemoveEntry(pkg.h, RPMTAG_FILEMTIMES);
	    headerRemoveEntry(pkg.h, RPMTAG_FILEDEVICES);
	    headerRemoveEntry(pkg.h, RPMTAG_FILEINODES);
	    headerRemoveEntry(pkg.h, RPMTAG_TRIGGERSCRIPTS);
	    headerRemoveEntry(pkg.h, RPMTAG_TRIGGERVERSION);
	    headerRemoveEntry(pkg.h, RPMTAG_TRIGGERFLAGS);
	    headerRemoveEntry(pkg.h, RPMTAG_TRIGGERNAME);
	    headerRemoveEntry(pkg.h, RPMTAG_CHANGELOGTIME);
	    headerRemoveEntry(pkg.h, RPMTAG_CHANGELOGNAME);
	    headerRemoveEntry(pkg.h, RPMTAG_CHANGELOGTEXT);
	    headerRemoveEntry(pkg.h, RPMTAG_ICON);
	    headerRemoveEntry(pkg.h, RPMTAG_GIF);
	    headerRemoveEntry(pkg.h, RPMTAG_VENDOR);
	    headerRemoveEntry(pkg.h, RPMTAG_EXCLUDE);
	    headerRemoveEntry(pkg.h, RPMTAG_EXCLUSIVE);
	    headerRemoveEntry(pkg.h, RPMTAG_DISTRIBUTION);
	    headerRemoveEntry(pkg.h, RPMTAG_VERIFYSCRIPT);
	  }
	  av_push(depslist, sv_setref_pv(newSVpv("", 0), "URPM::Package",
					 memcpy(malloc(sizeof(struct s_Package)), &pkg, sizeof(struct s_Package))));

	  /* only one element read */
	  XPUSHs(sv_2mortal(newSViv(av_len(depslist))));
	  XPUSHs(sv_2mortal(newSViv(av_len(depslist))));
	}
      }
      fdClose(fd);
    } else croak("first argument should contains a depslist ARRAY reference");
  } else croak("first argument should be a reference to HASH");

