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
  char *rflags;
  char *summary;
  unsigned flag;
  Header h;
};

struct s_Transaction {
  rpmdb db;
  rpmTransactionSet ts;
  FD_t script_fd;
};

struct s_TransactionData {
  SV* callback_open;
  SV* callback_close;
  SV* callback_trans;
  SV* callback_uninst;
  SV* callback_inst;
  long min_delta;
  SV *data; /* chain with another data user provided */
};

typedef rpmdb URPM__DB;
typedef struct s_Transaction* URPM__Transaction;
typedef struct s_Package* URPM__Package;

#define FLAG_ID             0x001fffffU
#define FLAG_RATE           0x00e00000U
#define FLAG_BASE           0x01000000U
#define FLAG_FORCE          0x02000000U
#define FLAG_INSTALLED      0x04000000U
#define FLAG_REQUESTED      0x08000000U
#define FLAG_REQUIRED       0x10000000U
#define FLAG_UPGRADE        0x20000000U
#define FLAG_OBSOLETE       0x40000000U
#define FLAG_NO_HEADER_FREE 0x80000000U

#define FLAG_ID_MAX         0x001ffffe
#define FLAG_ID_INVALID     0x001fffff

#define FLAG_RATE_POS       21
#define FLAG_RATE_MAX       5
#define FLAG_RATE_INVALID   0


#define FILENAME_TAG 1000000
#define FILESIZE_TAG 1000001

#define FILTER_MODE_ALL_FILES     0
#define FILTER_MODE_UPGRADE_FILES 1
#define FILTER_MODE_CONF_FILES    2

/* these are in rpmlib but not in rpmlib.h */
int readLead(FD_t fd, struct rpmlead *lead);
int rpmReadSignature(FD_t fd, Header *header, short sig_type);


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
	p = p + 1 + snprintf(p, sizeof(buff) - (p-buff), "%s", filename);
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
    if (pkg->summary == NULL) {
      char *summary = get_name(pkg->h, RPMTAG_SUMMARY);
      int len = 1 + strlen(summary);

      pkg->summary = memcpy(malloc(len), summary, len);
    }

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
	if (list[i][0] == '/') hv_fetch(provides, list[i], len, 1);
      }
    }

    /* update all provides */
    headerGetEntry(pkg->h, RPMTAG_PROVIDENAME, &type, (void **) &list, &count);
    if (list) {
      for (i = 0; i < count; ++i) {
	len = strlen(list[i]);
	if (!strncmp(list[i], "rpmlib(", 7)) continue;
	update_provide_entry(list[i], len, 1, pkg, provides);
      }
    }
  } else {
    char *ps, *s, *es;

    if ((s = pkg->requires) != NULL && *s != 0) {
      ps = strchr(s, '@');
      while(ps != NULL) {
	if (s[0] == '/') {
	  *ps = 0; es = strchr(s, '['); if (!es) es = strchr(s, ' '); *ps = '@';
	  hv_fetch(provides, s, es != NULL ? es-s : ps-s, 1);
	}
	s = ps + 1; ps = strchr(s, '@');
      }
      if (s[0] == '/') {
	es = strchr(s, '['); if (!es) es = strchr(s, ' ');
	hv_fetch(provides, s, es != NULL ? es-s : strlen(s), 1);
      }
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
parse_line(AV *depslist, HV *provides, URPM__Package pkg, char *buff, SV *urpm, SV *callback) {
  SV *sv_pkg;
  URPM__Package _pkg;
  char *tag, *data;
  int data_len;

  if ((tag = strchr(buff, '@')) != NULL && (data = strchr(tag+1, '@')) != NULL) {
    *tag++ = *data++ = 0;
    data_len = 1+strlen(data);
    if (!strcmp(tag, "info")) {
      pkg->info = memcpy(malloc(data_len), data, data_len);
      pkg->flag &= ~FLAG_ID;
      pkg->flag |= 1 + av_len(depslist);
      sv_pkg = sv_setref_pv(newSVpv("", 0), "URPM::Package",
			    _pkg = memcpy(malloc(sizeof(struct s_Package)), pkg, sizeof(struct s_Package)));
      if (callback != NULL) {
	/* now, a callback will be called for sure */
	dSP;
	PUSHMARK(sp);
	XPUSHs(urpm);
	XPUSHs(sv_pkg);
	PUTBACK;
	if (call_sv(callback, G_SCALAR) == 1) {
	  SPAGAIN;
	  if (!POPi) {
	    /* package should not be added in depslist, so we free it */
	    SvREFCNT_dec(sv_pkg);
	    sv_pkg = NULL;
	  }
	  PUTBACK;
	}
      }
      if (sv_pkg) {
	if (provides) update_provides(_pkg, provides);
	av_push(depslist, sv_pkg);
      }
      memset(pkg, 0, sizeof(struct s_Package));
    } else if (!strcmp(tag, "requires")) {
      free(pkg->requires); pkg->requires = memcpy(malloc(data_len), data, data_len);
    } else if (!strcmp(tag, "obsoletes")) {
      free(pkg->obsoletes); pkg->obsoletes = memcpy(malloc(data_len), data, data_len);
    } else if (!strcmp(tag, "conflicts")) {
      free(pkg->conflicts); pkg->conflicts = memcpy(malloc(data_len), data, data_len);
    } else if (!strcmp(tag, "provides")) {
      free(pkg->provides); pkg->provides = memcpy(malloc(data_len), data, data_len);
    } else if (!strcmp(tag, "summary")) {
      free(pkg->summary); pkg->summary = memcpy(malloc(data_len), data, data_len);
    }
  }
}

static int
update_header(char *filename, URPM__Package pkg, HV *provides, int packing, int keep_all_tags) {
  int d = open(filename, O_RDONLY);

  if (d >= 0) {
    unsigned char sig[4];

    if (read(d, &sig, sizeof(sig)) == sizeof(sig)) {
      lseek(d, 0, SEEK_SET);
      if (sig[0] == 0xed && sig[1] == 0xab && sig[2] == 0xee && sig[3] == 0xdb) {
	FD_t fd = fdDup(d);
	Header header;
	int isSource;

	close(d);
	if (fd != NULL && rpmReadPackageHeader(fd, &header, &isSource, NULL, NULL) == 0) {
	  struct stat sb;
	  char *basename;
	  int_32 size;

	  basename = strrchr(filename, '/');
	  fstat(fdFileno(fd), &sb);
	  fdClose(fd);
	  size = sb.st_size;
	  headerAddEntry(header, FILENAME_TAG, RPM_STRING_TYPE, basename != NULL ? basename + 1 : filename, 1);
	  headerAddEntry(header, FILESIZE_TAG, RPM_INT32_TYPE, &size, 1);

	  if (pkg->h && !(pkg->flag & FLAG_NO_HEADER_FREE)) headerFree(pkg->h);
	  pkg->h = header;
	  pkg->flag &= ~FLAG_NO_HEADER_FREE;

	  if (provides) {
	    update_provides(pkg, provides);
	    update_provides_files(pkg, provides);
	  }
	  if (packing) pack_header(pkg);
	  else if (!keep_all_tags) {
	    headerRemoveEntry(pkg->h, RPMTAG_POSTIN);
	    headerRemoveEntry(pkg->h, RPMTAG_POSTUN);
	    headerRemoveEntry(pkg->h, RPMTAG_PREIN);
	    headerRemoveEntry(pkg->h, RPMTAG_PREUN);
	    headerRemoveEntry(pkg->h, RPMTAG_FILEUSERNAME);
	    headerRemoveEntry(pkg->h, RPMTAG_FILEGROUPNAME);
	    headerRemoveEntry(pkg->h, RPMTAG_FILEVERIFYFLAGS);
	    headerRemoveEntry(pkg->h, RPMTAG_FILERDEVS);
	    headerRemoveEntry(pkg->h, RPMTAG_FILEMTIMES);
	    headerRemoveEntry(pkg->h, RPMTAG_FILEDEVICES);
	    headerRemoveEntry(pkg->h, RPMTAG_FILEINODES);
	    headerRemoveEntry(pkg->h, RPMTAG_TRIGGERSCRIPTS);
	    headerRemoveEntry(pkg->h, RPMTAG_TRIGGERVERSION);
	    headerRemoveEntry(pkg->h, RPMTAG_TRIGGERFLAGS);
	    headerRemoveEntry(pkg->h, RPMTAG_TRIGGERNAME);
	    headerRemoveEntry(pkg->h, RPMTAG_CHANGELOGTIME);
	    headerRemoveEntry(pkg->h, RPMTAG_CHANGELOGNAME);
	    headerRemoveEntry(pkg->h, RPMTAG_CHANGELOGTEXT);
	    headerRemoveEntry(pkg->h, RPMTAG_ICON);
	    headerRemoveEntry(pkg->h, RPMTAG_GIF);
	    headerRemoveEntry(pkg->h, RPMTAG_VENDOR);
	    headerRemoveEntry(pkg->h, RPMTAG_EXCLUDE);
	    headerRemoveEntry(pkg->h, RPMTAG_EXCLUSIVE);
	    headerRemoveEntry(pkg->h, RPMTAG_DISTRIBUTION);
	    headerRemoveEntry(pkg->h, RPMTAG_VERIFYSCRIPT);
	  }
	  return 1;
	}
      } else if (sig[0] == 0x8e && sig[1] == 0xad && sig[2] == 0xe8 && sig[3] == 0x01) {
	FD_t fd = fdDup(d);

	close(d);
	if (fd != NULL) {
	  if (pkg->h && !(pkg->flag & FLAG_NO_HEADER_FREE)) headerFree(pkg->h);
	  pkg->h = headerRead(fd, HEADER_MAGIC_YES);
	  pkg->flag &= ~FLAG_NO_HEADER_FREE;
	  fdClose(fd);
	  return 1;
	}
      }
    }
  }
  return 0;
}

static void
read_config_files(int force) {
  static int already = 0;

  if (!already || force) {
    rpmReadConfigFiles(NULL, NULL);
    already = 1;
  }
}

static void callback_empty(void) {}

static void *rpmRunTransactions_callback(const void *h,
					 const rpmCallbackType what,
					 const unsigned long amount,
					 const unsigned long total,
					 const void * pkgKey,
					 void * data) {
  static int last_amount;
  static FD_t fd = NULL;
  static struct timeval tprev;
  static struct timeval tcurr;
  long delta;
  int i;
  struct s_TransactionData *td = data;
  SV *callback = NULL;
  char *callback_type = NULL;
  char *callback_subtype = NULL;

  switch (what) {
  case RPMCALLBACK_INST_OPEN_FILE:
    callback = td->callback_open; callback_type = "open"; break;

  case RPMCALLBACK_INST_CLOSE_FILE:
    callback = td->callback_close; callback_type = "close"; break;

  case RPMCALLBACK_TRANS_START:
  case RPMCALLBACK_TRANS_PROGRESS:
  case RPMCALLBACK_TRANS_STOP:
    callback = td->callback_trans; callback_type = "trans"; break;

  case RPMCALLBACK_UNINST_START:
  case RPMCALLBACK_UNINST_PROGRESS:
  case RPMCALLBACK_UNINST_STOP:
    callback = td->callback_uninst; callback_type = "uninst"; break;

  case RPMCALLBACK_INST_START:
  case RPMCALLBACK_INST_PROGRESS:
    callback = td->callback_inst; callback_type = "inst"; break;
  }

  if (callback != NULL) {
    switch (what) {
    case RPMCALLBACK_TRANS_START:
    case RPMCALLBACK_UNINST_START:
    case RPMCALLBACK_INST_START:
      callback_subtype = "start"; break;
      gettimeofday(&tprev, NULL);

    case RPMCALLBACK_TRANS_PROGRESS:
    case RPMCALLBACK_UNINST_PROGRESS:
    case RPMCALLBACK_INST_PROGRESS:
      callback_subtype = "progress";
      gettimeofday(&tcurr, NULL);
      delta = 1000000 * (tcurr.tv_sec - tprev.tv_sec) + (tcurr.tv_usec - tprev.tv_usec);
      if (delta < td->min_delta && amount < total - 1)
	callback = NULL; /* avoid calling too often a given callback */
      else
	tprev = tcurr;
      break;

    case RPMCALLBACK_TRANS_STOP:
    case RPMCALLBACK_UNINST_STOP:
      callback_subtype = "stop"; break;
    }

    if (callback != NULL) {
      /* now, a callback will be called for sure */
      dSP;
      ENTER;
      SAVETMPS;
      PUSHMARK(sp);
      XPUSHs(td->data);
      XPUSHs(sv_2mortal(newSVpv(callback_type, 0)));
      XPUSHs(pkgKey != NULL ? sv_2mortal(newSViv((int)pkgKey - 1)) : &PL_sv_undef);
      if (callback_subtype != NULL) {
	XPUSHs(sv_2mortal(newSVpv(callback_subtype, 0)));
	XPUSHs(sv_2mortal(newSViv(amount)));
	XPUSHs(sv_2mortal(newSViv(total)));
      }
      PUTBACK;
      i = call_sv(callback, callback == td->callback_open ? G_SCALAR : G_DISCARD);
      SPAGAIN;
      if (i != 1 && callback == td->callback_open) croak("callback_open should return a file handle");
      if (i == 1) {
	i = POPi;
	fd = fdDup(i);
	fd = fdLink(fd, "persist perl-URPM");
	PUTBACK;
      } else if (callback == td->callback_close) {
	fd = fdFree(fd, "persist perl-URPM");
	if (fd) {
	  fdClose(fd);
	  fd = NULL;
	}
      }
      FREETMPS;
      LEAVE;
    }
  }
  return fd;
}

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
  free(pkg->rflags);
  free(pkg->summary);
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
  read_config_files(0);
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
  if (pkg->summary) {
    XPUSHs(sv_2mortal(newSVpv(pkg->summary, 0)));
  } else if (pkg->h) {
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
	char *eolarch = strchr(larch, '@');
	char *eorarch = strchr(rarch, '@');

	read_config_files(0);
	if (eolarch) *eolarch = 0; lscore = rpmMachineScore(RPM_MACHTABLE_INSTARCH, larch);
	if (eorarch) *eorarch = 0; rscore = rpmMachineScore(RPM_MACHTABLE_INSTARCH, rarch);
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
	if (eolarch) *eolarch = '@';
	if (eorarch) *eorarch = '@';
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
Pkg_header_filename(pkg)
  URPM::Package pkg
  PPCODE:
  if (pkg->info) {
    char *s, *eon, *eos;

    if ((eon = strchr(pkg->info, '@')) != NULL) {
      if ((s = strchr(eon+1, '@')) != NULL && (s = strchr(s+1, '@')) != NULL && (s = strchr(s+1, '@')) != NULL) {
	eos = strstr(s+1, ".rpm");
	if (eos != NULL) *eos = 0;
	if (eon != NULL) *eon = 0;
	XPUSHs(sv_2mortal(newSVpvf("%s:%s", pkg->info, s+1)));
	if (eon != NULL) *eon = '@';
	if (eos != NULL) *eos = '.';
      } else {
	XPUSHs(sv_2mortal(newSVpv(pkg->info, eon-pkg->info)));
      }
    }
  } else if (pkg->h) {
    char buff[1024];
    char *p = buff;
    char *name = get_name(pkg->h, RPMTAG_NAME);
    char *version = get_name(pkg->h, RPMTAG_VERSION);
    char *release = get_name(pkg->h, RPMTAG_RELEASE);
    char *arch = headerIsEntry(pkg->h, RPMTAG_SOURCEPACKAGE) ? "src" : get_name(pkg->h, RPMTAG_ARCH);
    char *filename = get_name(pkg->h, FILENAME_TAG);

    p += snprintf(buff, sizeof(buff), "%s-%s-%s.%s:", name, version, release, arch);
    if (filename) snprintf(p, sizeof(buff) - (p-buff), "%s-%s-%s.%s.rpm", name, version, release, arch);
    if (!filename || !strcmp(p, filename)) {
      *--p = 0;
    } else {
      p += snprintf(p, sizeof(buff) - (p-buff), "%s", filename);
      *(p -= 4) = 0; /* avoid .rpm */
    }
    XPUSHs(sv_2mortal(newSVpv(buff, p-buff)));
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
Pkg_changelog_time(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_int_32(SP, pkg->h, RPMTAG_CHANGELOGTIME);

void
Pkg_changelog_name(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, NULL, pkg->h, RPMTAG_CHANGELOGNAME, 0, 0);

void
Pkg_changelog_text(pkg)
  URPM::Package pkg
  PPCODE:
  SP = xreturn_list_str(SP, NULL, pkg->h, RPMTAG_CHANGELOGTEXT, 0, 0);

void
Pkg_pack_header(pkg)
  URPM::Package pkg
  CODE:
  pack_header(pkg);

int
Pkg_update_header(pkg, filename, packing=0, keep_all_tags=0)
  URPM::Package pkg
  char *filename
  int packing
  int keep_all_tags
  CODE:
  RETVAL = update_header(filename, pkg, NULL, packing, keep_all_tags);
  OUTPUT:
  RETVAL

void
Pkg_free_header(pkg)
  URPM::Package pkg
  CODE:
  if (pkg->h && !(pkg->flag & FLAG_NO_HEADER_FREE)) headerFree(pkg->h);
  pkg->h = NULL;

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
    if (pkg->summary && *pkg->summary) {
      size = snprintf(buff, sizeof(buff), "@summary@%s\n", pkg->summary);
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

    if ((fd = fdDup(fileno)) != NULL) {
      headerWrite(fd, pkg->h, HEADER_MAGIC_YES);
      fdClose(fd);
    } else croak("unable to get rpmio handle on fileno %d", fileno);
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

int
Pkg_flag_obsolete(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_OBSOLETE;
  OUTPUT:
  RETVAL

int
Pkg_set_flag_obsolete(pkg, value=1)
  URPM::Package pkg
  int value
  CODE:
  RETVAL = pkg->flag & FLAG_OBSOLETE;
  if (value) pkg->flag |= FLAG_OBSOLETE;
  else       pkg->flag &= ~FLAG_OBSOLETE;
  OUTPUT:
  RETVAL

int
Pkg_flag_selected(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = pkg->flag & FLAG_UPGRADE ? pkg->flag & (FLAG_BASE | FLAG_REQUESTED | FLAG_REQUIRED) : 0;
  OUTPUT:
  RETVAL

int
Pkg_flag_available(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = (pkg->flag & FLAG_INSTALLED && !(pkg->flag & FLAG_UPGRADE)) ||
           (pkg->flag & FLAG_UPGRADE ? pkg->flag & (FLAG_BASE | FLAG_REQUESTED | FLAG_REQUIRED) : 0);
  OUTPUT:
  RETVAL

int
Pkg_rate(pkg)
  URPM::Package pkg
  CODE:
  RETVAL = (pkg->flag & FLAG_RATE) >> FLAG_RATE_POS;
  OUTPUT:
  RETVAL

int
Pkg_set_rate(pkg, rate)
  URPM::Package pkg
  int rate
  CODE:
  RETVAL = (pkg->flag & FLAG_RATE) >> FLAG_RATE_POS;
  pkg->flag &= ~FLAG_RATE;
  pkg->flag |= (rate >= 0 && rate <= FLAG_RATE_MAX ? rate : FLAG_RATE_INVALID) << FLAG_RATE_POS;
  OUTPUT:
  RETVAL

void
Pkg_rflags(pkg)
  URPM::Package pkg
  PREINIT:
  I32 gimme = GIMME_V;
  PPCODE:
  if (gimme == G_ARRAY && pkg->rflags != NULL) {
    char *s = pkg->rflags;
    char *eos;
    while ((eos = strchr(s, '\t')) != NULL) {
      XPUSHs(sv_2mortal(newSVpv(s, eos-s)));
      s = eos + 1;
    }
    XPUSHs(sv_2mortal(newSVpv(s, 0)));
  }

void
Pkg_set_rflags(pkg, ...)
  URPM::Package pkg
  PREINIT:
  I32 gimme = GIMME_V;
  char *new_rflags;
  STRLEN total_len;
  int i;
  PPCODE:
  total_len = 0;
  for (i = 1; i < items; ++i) {
    STRLEN len;
    char *s = SvPV(ST(i), len);
    total_len += len + 1;
  }

  new_rflags = malloc(total_len);
  total_len = 0;
  for (i = 1; i < items; ++i) {
    STRLEN len;
    char *s = SvPV(ST(i), len);
    memcpy(new_rflags + total_len, s, len);
    new_rflags[total_len + len] = '\t';
    total_len += len + 1;
  }
  new_rflags[total_len - 1] = 0; /* but mark end-of-string correctly */

  if (gimme == G_ARRAY && pkg->rflags != NULL) {
    char *s = pkg->rflags;
    char *eos;
    while ((eos = strchr(s, '\t')) != NULL) {
      XPUSHs(sv_2mortal(newSVpv(s, eos-s)));
      s = eos + 1;
    }
    XPUSHs(sv_2mortal(newSVpv(s, 0)));
  }

  free(pkg->rflags);
  pkg->rflags = new_rflags;


MODULE = URPM            PACKAGE = URPM::DB            PREFIX = Db_

URPM::DB
Db_open(prefix="", write_perm=0)
  char *prefix
  int write_perm
  PREINIT:
  rpmdb db;
  rpmErrorCallBackType old_cb;
  CODE:
  read_config_files(0);
  old_cb = rpmErrorSetCallback(callback_empty);
  rpmSetVerbosity(RPMMESS_FATALERROR);
  RETVAL = rpmdbOpen(prefix, &db, write_perm ? O_RDWR | O_CREAT : O_RDONLY, 0644) == 0 ? db : NULL;
  rpmErrorSetCallback(old_cb);
  rpmSetVerbosity(RPMMESS_NORMAL);
  OUTPUT:
  RETVAL

int
Db_rebuild(prefix="")
  char *prefix
  PREINIT:
  rpmdb db;
  rpmErrorCallBackType old_cb;
  CODE:
  read_config_files(0);
  old_cb = rpmErrorSetCallback(callback_empty);
  rpmSetVerbosity(RPMMESS_FATALERROR);
  RETVAL = rpmdbRebuild(prefix) == 0;
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

      PUSHMARK(SP);
      XPUSHs(sv_2mortal(sv_setref_pv(newSVpv("", 0), "URPM::Package", pkg)));
      PUTBACK;

      call_sv(callback, G_DISCARD | G_SCALAR);
      pkg->h = 0; /* avoid using it anymore, in case it has been copied inside callback */
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
    else if (!strcmp(tag, "whatconflicts"))
      rpmtag = RPMTAG_CONFLICTNAME;
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

	  PUSHMARK(SP);
	  XPUSHs(sv_2mortal(sv_setref_pv(newSVpv("", 0), "URPM::Package", pkg)));
	  PUTBACK;

	  call_sv(callback, G_DISCARD | G_SCALAR);
	  pkg->h = 0; /* avoid using it anymore, in case it has been copied inside callback */
	}
	++count;
      }
      rpmdbFreeIterator(mi);
    } 
  } else croak("bad arguments list");
  RETVAL = count;
  OUTPUT:
  RETVAL

URPM::Transaction
Db_create_transaction(db, prefix="/")
  URPM::DB db
  char *prefix
  CODE:
  if ((RETVAL = calloc(1, sizeof(struct s_Transaction))) != NULL) {
    /* rpmSetVerbosity(RPMMESS_DEBUG); TODO check remove and add in same transaction */
    RETVAL->db = db;
    RETVAL->ts = rpmtransCreateSet(db, prefix);
  }
  OUTPUT:
  RETVAL


MODULE = URPM            PACKAGE = URPM::Transaction   PREFIX = Trans_

void
Trans_DESTROY(trans)
  URPM::Transaction trans
  CODE:
  /* db should be SV with reference count updated */
  rpmtransFree(trans->ts);
  if (trans->script_fd != NULL) fdClose(trans->script_fd);
  free(trans);

void
Trans_set_script_fd(trans, fdno)
  URPM::Transaction trans
  int fdno
  CODE:
  if (trans->script_fd != NULL) fdClose(trans->script_fd);
  trans->script_fd = fdDup(fdno);
  rpmtransSetScriptFd(trans->ts, trans->script_fd);

int
Trans_add(trans, pkg, ...)
  URPM::Transaction trans
  URPM::Package pkg
  CODE:
  if ((pkg->flag & FLAG_ID) <= FLAG_ID_MAX && pkg->h != NULL) {
    int update = 0;
    rpmRelocation *relocations = NULL;
    /* compability mode with older interface of add */
    if (items == 3) {
      update = SvIV(ST(2));
    } else if (items > 3) {
      int i;
      for (i = 2; i < items-1; i+=2) {
	STRLEN len;
	char *s = SvPV(ST(i), len);

	if (len == 6 && !memcmp(s, "update", 6)) {
	  update = SvIV(ST(i+1));
	} else if (len == 11 && !memcmp(s, "excludepath", 11)) {
	  if (SvROK(ST(i+1)) && SvTYPE(SvRV(ST(i+1))) == SVt_PVAV) {
	    AV *excludepath = (AV*)SvRV(ST(i+1));
	    I32 j = 1 + av_len(excludepath);
	    relocations = calloc(2 + av_len(excludepath), sizeof(rpmRelocation));
	    while (--j >= 0) {
	      SV **e = av_fetch(excludepath, j, 0);
	      if (e != NULL && *e != NULL) {
		relocations[j].oldPath = SvPV_nolen(*e);
	      }
	    }
	  }
	}
      }
    }
    RETVAL = rpmtransAddPackage(trans->ts, pkg->h, NULL, (void *)(1+(pkg->flag & FLAG_ID)), update, relocations) == 0;
    /* free allocated memory, check rpm is copying it just above, at least in 4.0.4 */
    free(relocations);
  } else RETVAL = 0;
  OUTPUT:
  RETVAL

int
Trans_remove(trans, name)
  URPM::Transaction trans
  char *name
  PREINIT:
  Header h;
  rpmdbMatchIterator mi;
  int count = 0;
  CODE:
  mi = rpmdbInitIterator(trans->db, RPMDBI_LABEL, name, 0);
  while (h = rpmdbNextIterator(mi)) {
    unsigned int recOffset = rpmdbGetIteratorOffset(mi);
    count += recOffset != 0 && rpmtransRemovePackage(trans->ts, recOffset) == 0;
  }
  rpmdbFreeIterator(mi);
  RETVAL=count;
  OUTPUT:
  RETVAL

void
Trans_check(trans)
  URPM::Transaction trans
  PREINIT:
  I32 gimme = GIMME_V;
  rpmDependencyConflict conflicts;
  int num_conflicts;
  PPCODE:
  if (rpmdepCheck(trans->ts, &conflicts, &num_conflicts)) {
    if (gimme == G_SCALAR) {
      XPUSHs(sv_2mortal(newSViv(0)));
    } else if (gimme == G_ARRAY) {
      XPUSHs(sv_2mortal(newSVpv("error while checking dependencies", 0)));
    }
  } else if (conflicts) {
    if (gimme == G_SCALAR) {
      XPUSHs(sv_2mortal(newSViv(0)));
    } else if (gimme == G_ARRAY) {
      char buff[1024];
      int i;

      for (i = 0; i < num_conflicts; ++i) {
	char *p = buff;

	p += snprintf(p, sizeof(buff) - (p-buff), "%s@%s", 
		      conflicts[i].sense == RPMDEP_SENSE_REQUIRES ? "requires" : "conflicts",
		      conflicts[i].needsName);
	if (sizeof(buff) - (p-buff) > 4 && conflicts[i].needsFlags & RPMSENSE_SENSEMASK) {
	  *p++ = ' ';
	  if (conflicts[i].needsFlags & RPMSENSE_LESS)    *p++ = '<';
	  if (conflicts[i].needsFlags & RPMSENSE_GREATER) *p++ = '>';
	  if (conflicts[i].needsFlags & RPMSENSE_EQUAL)   *p++ = '=';
	  if ((conflicts[i].needsFlags & RPMSENSE_SENSEMASK) == RPMSENSE_EQUAL) *p++ = '=';
	  *p++ = ' ';
	  p += snprintf(p, sizeof(buff) - (p-buff), "%s", conflicts[i].needsVersion);
	}
	p += snprintf(p, sizeof(buff) - (p-buff), "@%s-%s-%s",
		      conflicts[i].byName, conflicts[i].byVersion, conflicts[i].byRelease);
	*p = 0;
	XPUSHs(sv_2mortal(newSVpv(buff, p-buff)));
      }
    }
    rpmdepFreeConflicts(conflicts, num_conflicts);
  } else if (gimme == G_SCALAR) {
    XPUSHs(sv_2mortal(newSViv(1)));
  }

int
Trans_order(trans)
  URPM::Transaction trans
  PREINIT:
  I32 gimme = GIMME_V;
  PPCODE:
  if (rpmdepOrder(trans->ts) == 0) {
    if (gimme == G_SCALAR) {
      XPUSHs(sv_2mortal(newSViv(1)));
    }
  } else {
    if (gimme == G_SCALAR) {
      XPUSHs(sv_2mortal(newSViv(0)));
    } else if (gimme == G_ARRAY) {
      XPUSHs(sv_2mortal(newSVpv("error while ordering dependencies", 0)));
    }
  }

void
Trans_run(trans, data, ...)
  URPM::Transaction trans
  SV *data
  PREINIT:
  /* available callback:
       callback(data, 'open'|'close', id|undef)
       callback(data, 'trans'|'uninst'|'inst', id|undef, 'start'|'progress'|'stop', amount, total)
  */
  struct s_TransactionData td = { NULL, NULL, NULL, NULL, NULL, 100000, data };
  rpmtransFlags transFlags = RPMTRANS_FLAG_NONE;
  int probFilter = 0;
  rpmProblemSet probs;
  int translate_message = 0;
  int i;
  PPCODE:
  for (i = 2; i < items-1; i+=2) {
    STRLEN len;
    char *s = SvPV(ST(i), len);

    if (len == 4 && !memcmp(s, "test", 4)) {
      if (SvIV(ST(i+1))) transFlags |= RPMTRANS_FLAG_TEST;
    } else if (len == 5) {
      if (!memcmp(s, "force", 5)) {
	if (SvIV(ST(i+1))) probFilter |= (RPMPROB_FILTER_REPLACEPKG | 
					  RPMPROB_FILTER_REPLACEOLDFILES |
					  RPMPROB_FILTER_REPLACENEWFILES |
					  RPMPROB_FILTER_OLDPACKAGE);
      } else if (!memcmp(s, "delta", 5))
	td.min_delta = SvIV(ST(i+1));
    } else if (len == 6 && !memcmp(s, "nosize", 6)) {
      if (SvIV(ST(i+1))) probFilter |= RPMPROB_FILTER_DISKSPACE;
    } else if (len == 10 && !memcmp(s, "oldpackage", 10)) {
      if (SvIV(ST(i+1))) probFilter |= RPMPROB_FILTER_OLDPACKAGE;
    } else if (len == 17 && !memcmp(s, "translate_message", 17))
      translate_message = 1;
    else if (len >= 9 && !memcmp(s, "callback_", 9)) {
      if (len == 9+4 && !memcmp(s+9, "open", 4))
	td.callback_open = ST(i+1);
      else if (len == 9+5 && !memcmp(s+9, "close", 5))
	td.callback_close = ST(i+1);
      else if (len == 9+5 && !memcmp(s+9, "trans", 5))
	td.callback_trans = ST(i+1);
      else if (len == 9+6 && !memcmp(s+9, "uninst", 6))
	td.callback_uninst = ST(i+1);
      else if (len == 9+4 && !memcmp(s+9, "inst", 4))
	td.callback_inst = ST(i+1);
    }
  }
  if (rpmRunTransactions(trans->ts, rpmRunTransactions_callback, &td, NULL, &probs, transFlags, probFilter)) {
    EXTEND(SP, probs->numProblems);
    for (i = 0; i < probs->numProblems; i++) {
      if (translate_message) {
	/* translate error using rpm localization */
	const char *buf = rpmProblemString(probs->probs + i);
	PUSHs(sv_2mortal(newSVpv(buf, 0)));
	_free(buf);
      } else {
	const char *pkgNEVR = (probs->probs[i].pkgNEVR ? probs->probs[i].pkgNEVR : "");
	const char *altNEVR = probs->probs[i].altNEVR ? probs->probs[i].altNEVR : "";
	const char *s = probs->probs[i].str1 ? probs->probs[i].str1 : "";
	SV *sv;

	switch (probs->probs[i].type) {
	case RPMPROB_BADARCH:
	  sv = newSVpvf("badarch@%s", pkgNEVR); break;

	case RPMPROB_BADOS:
	  sv = newSVpvf("bados@%s", pkgNEVR); break;

	case RPMPROB_PKG_INSTALLED:
	  sv = newSVpvf("installed@%s", pkgNEVR); break;

	case RPMPROB_BADRELOCATE:
	  sv = newSVpvf("badrelocate@%s@%s", pkgNEVR, s); break;

	case RPMPROB_NEW_FILE_CONFLICT:
	case RPMPROB_FILE_CONFLICT:
	  sv = newSVpvf("conflicts@%s@%s@%s", pkgNEVR, altNEVR, s); break;

	case RPMPROB_OLDPACKAGE:
	  sv = newSVpvf("installed@%s@%s", pkgNEVR, altNEVR); break;

	case RPMPROB_DISKSPACE:
	  sv = newSVpvf("diskspace@%s@%s@%ld", pkgNEVR, s, probs->probs[i].ulong1); break;

	case RPMPROB_DISKNODES:
	  sv = newSVpvf("disknodes@%s@%s@%ld", pkgNEVR, s, probs->probs[i].ulong1); break;

	case RPMPROB_BADPRETRANS:
	  sv = newSVpvf("badpretrans@%s@%s@%s", pkgNEVR, s, strerror(probs->probs[i].ulong1)); break;

	case RPMPROB_REQUIRES:
	  sv = newSVpvf("requires@%s@%s@%s", pkgNEVR, altNEVR+2); break;

	case RPMPROB_CONFLICT:
	  sv = newSVpvf("conflicts@%s@%s", pkgNEVR, altNEVR+2); break;

	default:
	  sv = newSVpvf("unknown@%s", pkgNEVR); break;
	}
	PUSHs(sv_2mortal(sv));
      }
    }
  }

MODULE = URPM            PACKAGE = URPM                PREFIX = Urpm_


void
Urpm_read_config_files()
  CODE:
  read_config_files(1); /* force re-read of configuration files */

int
Urpm_ranges_overlap(a, b)
  char *a
  char *b
  PREINIT:
  char *sa = a, *sb = b;
  int aflags = 0, bflags = 0;
  CODE:
  while (*sa && *sa != ' ' && *sa != '[' && *sa != '<' && *sa != '>' && *sa != '=' && *sa == *sb) {
    ++sa;
    ++sb;
  }
  if (*sa && *sa != ' ' && *sa != '[' && *sa != '<' && *sa != '>' && *sa != '=' ||
      *sb && *sb != ' ' && *sb != '[' && *sb != '<' && *sb != '>' && *sb != '=') {
    /* the strings are sure to be different */
    RETVAL = 0;
  } else {
    while (*sa) {
      if (*sa == ' ' || *sa == '[' || *sa == '*' || *sa == ']');
      else if (*sa == '<') aflags |= RPMSENSE_LESS;
      else if (*sa == '>') aflags |= RPMSENSE_GREATER;
      else if (*sa == '=') aflags |= RPMSENSE_EQUAL;
      else break;
      ++sa;
    }
    while (*sb) {
      if (*sb == ' ' || *sb == '[' || *sb == '*' || *sb == ']');
      else if (*sb == '<') bflags |= RPMSENSE_LESS;
      else if (*sb == '>') bflags |= RPMSENSE_GREATER;
      else if (*sb == '=') bflags |= RPMSENSE_EQUAL;
      else break;
      ++sb;
    }
    if (!aflags || !bflags)
      RETVAL = 1; /* really faster to test it there instead of later */
    else {
      char *eosa = strchr(sa, ']');
      char *eosb = strchr(sb, ']');

      if (eosa) *eosa = 0;
      if (eosb) *eosb = 0;
      RETVAL = rpmRangesOverlap("", sa, aflags, "", sb, bflags);
      if (eosb) *eosb = ']';
      if (eosa) *eosa = ']';
    }
  }
  OUTPUT:
  RETVAL

void
Urpm_parse_synthesis(urpm, filename, ...)
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
      SV *callback = NULL;

      if (items > 2) {
	int i;
	for (i = 2; i < items-1; i+=2) {
	  STRLEN len;
	  char *s = SvPV(ST(i), len);

	  if (len == 8 && !memcmp(s, "callback", 8)) {
	    callback = ST(i+1);
	  }
	}
      }

      if ((f = gzopen(filename, "rb")) != NULL) {
	memset(&pkg, 0, sizeof(struct s_Package));
	buff[sizeof(buff)-1] = 0;
	p = buff;
	while ((buff_len = gzread(f, p, sizeof(buff)-1-(p-buff)) + (p-buff)) != 0) {
	  p = buff;
	  if ((eol = strchr(p, '\n')) != NULL) {
	    do {
	      *eol++ = 0;
	      parse_line(depslist, provides, &pkg, p, urpm, callback);
	      p = eol;
	    } while ((eol = strchr(p, '\n')) != NULL);
	  } else {
	    /* a line larger than sizeof(buff) has been encountered, bad file problably */
	    break;
	  }
	  if (gzeof(f)) {
	    parse_line(depslist, provides, &pkg, p, urpm, callback);
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
Urpm_parse_hdlist(urpm, filename, ...)
  SV *urpm
  char *filename
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
	int packing = 0;
	SV *callback = NULL;

	/* compability mode with older interface of parse_hdlist */
	if (items == 3) {
	  packing = SvIV(ST(2));
	} else if (items > 3) {
	  int i;
	  for (i = 2; i < items-1; i+=2) {
	    STRLEN len;
	    char *s = SvPV(ST(i), len);

	    if (len == 7 && !memcmp(s, "packing", 7)) {
	      packing = SvIV(ST(i+1));
	    } else if (len == 8 && !memcmp(s, "callback", 8)) {
	      callback = ST(i+1);
	    }
	  }
	}

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
	    struct s_Package pkg, *_pkg;
	    SV *sv_pkg;

	    memset(&pkg, 0, sizeof(struct s_Package));
	    pkg.flag = 1 + av_len(depslist);
	    pkg.h = header;
	    sv_pkg = sv_setref_pv(newSVpv("", 0), "URPM::Package",
				  _pkg = memcpy(malloc(sizeof(struct s_Package)), &pkg, sizeof(struct s_Package)));
	    if (callback != NULL) {
	      int count;

	      /* now, a callback will be called for sure */
	      ENTER;
	      SAVETMPS;
	      PUSHMARK(sp);
	      XPUSHs(urpm);
	      XPUSHs(sv_pkg);
	      PUTBACK;
	      count = call_sv(callback, G_SCALAR);
	      SPAGAIN;
	      if (count == 1 && !POPi) {
		/* package should not be added in depslist, so we free it */
		SvREFCNT_dec(sv_pkg);
		sv_pkg = NULL;
	      }
	      PUTBACK;
	      FREETMPS;
	      LEAVE;
	    }
	    if (sv_pkg) {
	      if (provides) {
		update_provides(_pkg, provides);
		update_provides_files(_pkg, provides);
	      }
	      if (packing) pack_header(_pkg);
	      av_push(depslist, sv_pkg);
	    }
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
Urpm_parse_rpm(urpm, filename, packing=0, keep_all_tags=0)
  SV *urpm
  char *filename
  PPCODE:
  if (SvROK(urpm) && SvTYPE(SvRV(urpm)) == SVt_PVHV) {
    SV **fdepslist = hv_fetch((HV*)SvRV(urpm), "depslist", 8, 0);
    AV *depslist = fdepslist && SvROK(*fdepslist) && SvTYPE(SvRV(*fdepslist)) == SVt_PVAV ? (AV*)SvRV(*fdepslist) : NULL;
    SV **fprovides = hv_fetch((HV*)SvRV(urpm), "provides", 8, 0);
    HV *provides = fprovides && SvROK(*fprovides) && SvTYPE(SvRV(*fprovides)) == SVt_PVHV ? (HV*)SvRV(*fprovides) : NULL;

    if (depslist != NULL) {
      struct s_Package pkg;
      int packing = 0;
      int keep_all_tags = 0;
      SV *callback = NULL;

      /* compability mode with older interface of parse_hdlist */
      if (items == 3) {
	packing = SvIV(ST(2));
      } else if (items > 3) {
	int i;
	for (i = 2; i < items-1; i+=2) {
	  STRLEN len;
	  char *s = SvPV(ST(i), len);

	  if (len == 7 && !memcmp(s, "packing", 7)) {
	    packing = SvIV(ST(i + 1));
	  } else if (len == 13 && !memcmp(s, "keep_all_tags", 13)) {
	    keep_all_tags = SvIV(ST(i+1));
	  } else if (len == 8 && !memcmp(s, "callback", 8)) {
	    callback = ST(i+1);
	  }
	}
      }
      memset(&pkg, 0, sizeof(struct s_Package));
      pkg.flag = 1 + av_len(depslist);
      if (update_header(filename, &pkg, provides, packing, keep_all_tags)) {
	av_push(depslist, sv_setref_pv(newSVpv("", 0), "URPM::Package",
				       memcpy(malloc(sizeof(struct s_Package)), &pkg, sizeof(struct s_Package))));

	/* only one element read */
	XPUSHs(sv_2mortal(newSViv(av_len(depslist))));
	XPUSHs(sv_2mortal(newSViv(av_len(depslist))));
      }
    } else croak("first argument should contains a depslist ARRAY reference");
  } else croak("first argument should be a reference to HASH");

char *
Urpm_verify_rpm(filename, ...)
  char *filename
  PREINIT:
  int nopgp = 0, nogpg = 0, nomd5 = 0;
  struct rpmlead lead;
  Header sig;
  HeaderIterator sigIter;
  const void *ptr;
  int_32 tag, type, count;
  FD_t fd, ofd;
  const char *tmpfile = NULL;
  int i;
  char result[8*BUFSIZ];
  unsigned char buffer[8192];
  CODE:
  for (i = 1; i < items-1; i+=2) {
    STRLEN len;
    char *s = SvPV(ST(i), len);

    if (len == 5) {
      if (!memcmp(s, "nopgp", 5))
	nopgp = SvIV(ST(i+1));
      else if (!memcmp(s, "nogpg", 5))
	nogpg = SvIV(ST(i+1));
      else if (!memcmp(s, "nomd5", 5))
	nomd5 = SvIV(ST(i+1));
    } else if (len == 12 && !memcmp(s, "tmp_filename", 12))
      tmpfile = SvPV_nolen(ST(i+1));
  }
  RETVAL = NULL;
  fd = fdOpen(filename, O_RDONLY, 0);
  if (fdFileno(fd) < 0) {
    RETVAL = "Couldn't open file";
  } else {
    memset(&lead, 0, sizeof(lead));
    if (readLead(fd, &lead)) {
      RETVAL = "Could not read lead bytes";
    } else if (lead.major == 1) {
      RETVAL = "RPM version of package doesn't support signatures";
    } else {
      i = rpmReadSignature(fd, &sig, lead.signature_type);
      if (i != RPMRC_OK && i != RPMRC_BADSIZE) {
	RETVAL = "Could not read signature block (`rpmReadSignature' failed)";
      } else if (!sig) {
	RETVAL = "No signatures";
      } else if (makeTempFile(NULL, &tmpfile, &ofd)) {
	if (tmpfile) {
	  unlink(tmpfile);
	  ofd = Fopen(tmpfile, "w+x.ufdio");
	  if (ofd == NULL || Ferror(fd))
	    RETVAL = "Unable to create tempory file";
	} else
	  if (makeTempFile(NULL, &tmpfile, &ofd))
	    RETVAL = "Unable to create tempory file";
      }
      if (!RETVAL) {
	while ((i = fdRead(fd, buffer, sizeof(buffer))) != 0) {
	  if (i == -1) {
	    RETVAL = "Error reading file";
	    break;
	  }
	  if (fdWrite(ofd, buffer, i) < 0) {
	    RETVAL = "Error writing temp file";
	    break;
	  }
	}
	if (!RETVAL) {
	  int res2 = 0;
	  int res3;
	  unsigned char missingKeys[7164] = { 0 };
	  unsigned char untrustedKeys[7164] = { 0 };

	  buffer[0] = 0; /* reset buffer as it is used again */
	  for (sigIter = headerInitIterator(sig);
	       headerNextIterator(sigIter, &tag, &type, &ptr, &count);
	       ptr = headerFreeData(ptr, type)) {
	    switch (tag) {
	    case RPMSIGTAG_PGP5:
	    case RPMSIGTAG_PGP:
	      if (nopgp) continue;
	      break;

	    case RPMSIGTAG_GPG:
	      if (nogpg) continue;
	      break;

	    case RPMSIGTAG_LEMD5_2:
	    case RPMSIGTAG_LEMD5_1:
	    case RPMSIGTAG_MD5:
	      if (nomd5) continue;
	      break;

	    default:
	      continue;
	    }
	    if (ptr == NULL) continue;

	    if ((res3 = rpmVerifySignature(tmpfile, tag, ptr, count, result)) != RPMSIG_OK) {
	      /* all the following code directly taken from lib/rpmchecksig.c */
	      if (rpmIsVerbose()) {
		strcat(buffer, result);
		res2 = 1;
	      } else {
		char *tempKey;
		switch (tag) {
		case RPMSIGTAG_SIZE:
		  strcat(buffer, "SIZE ");
		  res2 = 1;
		  break;
		case RPMSIGTAG_LEMD5_2:
		case RPMSIGTAG_LEMD5_1:
		case RPMSIGTAG_MD5:
		  strcat(buffer, "MD5 ");
		  res2 = 1;
		  break;
		case RPMSIGTAG_PGP5:	/* XXX legacy */
		case RPMSIGTAG_PGP:
		  switch (res3) {
		  case RPMSIG_NOKEY:
		    res2 = 1;
		    /*@fallthrough@*/
		  case RPMSIG_NOTTRUSTED:
		    {   int offset = 7;
		    strcat(buffer, "(PGP) ");
		    tempKey = strstr(result, "Key ID");
		    if (tempKey == NULL) {
		      tempKey = strstr(result, "keyid:");
		      offset = 9;
		    }
		    if (tempKey) {
		      if (res3 == RPMSIG_NOKEY) {
			strcat(missingKeys, " PGP#");
			/*@-compdef@*/
			strncat(missingKeys, tempKey + offset, 8);
			/*@=compdef@*/
		      } else {
			strcat(untrustedKeys, " PGP#");
			/*@-compdef@*/
			strncat(untrustedKeys, tempKey + offset, 8);
			/*@=compdef@*/
		      }
		    }
		    }   break;
		  default:
		    strcat(buffer, "PGP ");
		    res2 = 1;
		    break;
		  }
		  break;
		case RPMSIGTAG_GPG:
		  /* Do not consider this a failure */
		  switch (res3) {
		  case RPMSIG_NOKEY:
		    strcat(buffer, "(GPG) ");
		    strcat(missingKeys, " GPG#");
		    tempKey = strstr(result, "key ID");
		    if (tempKey)
		      /*@-compdef@*/
		      strncat(missingKeys, tempKey+7, 8);
		    /*@=compdef@*/
		    res2 = 1;
		    break;
		  default:
		    strcat(buffer, "GPG ");
		    res2 = 1;
		    break;
		  }
		  break;
		default:
		  strcat(buffer, "?UnknownSignatureType? ");
		  res2 = 1;
		  break;
		}
	      }
	    } else {
	      if (rpmIsVerbose()) {
		strcat(buffer, result);
	      } else {
		switch (tag) {
		case RPMSIGTAG_SIZE:
		  strcat(buffer, "size ");
		  break;
		case RPMSIGTAG_LEMD5_2:
		case RPMSIGTAG_LEMD5_1:
		case RPMSIGTAG_MD5:
		  strcat(buffer, "md5 ");
		  break;
		case RPMSIGTAG_PGP5:	/* XXX legacy */
		case RPMSIGTAG_PGP:
		  strcat(buffer, "pgp ");
		  break;
		case RPMSIGTAG_GPG:
		  strcat(buffer, "gpg ");
		  break;
		default:
		  strcat(buffer, "??? ");
		  break;
		}
	      }
	    }
	  }
	  sigIter = headerFreeIterator(sigIter);

	  if (!rpmIsVerbose()) {
	    if (res2) {
	      sprintf(buffer+strlen(buffer), "%s%s%s%s%s%s%s",
		      _("NOT OK"),
		      (missingKeys[0] != '\0') ? _(" (MISSING KEYS:") : "",
		      (char *)missingKeys,
		      (missingKeys[0] != '\0') ? _(") ") : "",
		      (untrustedKeys[0] != '\0') ? _(" (UNTRUSTED KEYS:") : "",
		      (char *)untrustedKeys,
		      (untrustedKeys[0] != '\0') ? _(")") : "");
	    } else {
	      sprintf(buffer+strlen(buffer), "%s%s%s%s%s%s%s",
		      _("OK"),
		      (missingKeys[0] != '\0') ? _(" (MISSING KEYS:") : "",
		      (char *)missingKeys,
		      (missingKeys[0] != '\0') ? _(") ") : "",
		      (untrustedKeys[0] != '\0') ? _(" (UNTRUSTED KEYS:") : "",
		      (char *)untrustedKeys,
		      (untrustedKeys[0] != '\0') ? _(")") : "");
	    }
	  }

	  RETVAL = buffer;
	}
      }
      fdClose(ofd);
      unlink(tmpfile);
    }
    fdClose(fd);
  }
  if (!RETVAL) RETVAL = "";
  OUTPUT:
  RETVAL
