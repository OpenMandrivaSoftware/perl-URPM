#define RPM_NULL_TYPE   0
#define RPM_CHAR_TYPE   RPM_UINT8_TYPE
#define RPM_INT8_TYPE   RPM_UINT8_TYPE
#define RPM_INT16_TYPE  RPM_UINT16_TYPE
#define RPM_INT32_TYPE  RPM_UINT32_TYPE

#include <rpm/rpmio.h>
#include <rpm/pkgio.h>
#include <rpm/rpmcb.h>
#   define _RPMTAG_INTERNAL
#include <rpm/rpmtag.h>
#include <rpm/rpmts.h>


enum hMagic {
	HEADER_MAGIC_NO             = 0,
	HEADER_MAGIC_YES            = 1
};


typedef uint32_t *        hTAG_t;
typedef uint32_t *        hTYP_t;
typedef const void *    hPTR_t;
typedef uint32_t *        hCNT_t;
typedef	uint32_t int_32;
typedef	uint16_t uint_16;
typedef	uint8_t byte;
typedef union hRET_s {
	const void * ptr;
	const char ** argv;
	const char * str;
	uint32_t * ui32p;
	uint16_t * ui16p;
	uint32_t * i32p;
	uint16_t * i16p;
	uint8_t * i8p;
} * hRET_t;

static inline int headerGetEntry(Header h, int_32 tag, hTYP_t type, void ** p, hCNT_t c){
	HE_t he = memset(alloca(sizeof(*he)), 0, sizeof(*he));
	int rc;
	
	he->tag = tag;
	rc = headerGet(h, he, tag);
	if (rc) {
		if (type) *type = he->t;
		if (p) *(void **) p = he->p.ptr;
		if (c) *c = he->c;
	}
	return rc;
}

/*static Header headerRead(FD_t fd, enum hMagic magicp){

}*/

static int headerAddEntry(Header h, int_32 tag, int_32 type, const void * p, int_32 c) {
	HE_t he = memset(alloca(sizeof(*he)), 0, sizeof(*he));
	he->tag = tag;
	he->t = type;
	he->p.str = p;
	he->c = c;
	return headerPut(h, he, 0);
}

static int headerRemoveEntry(Header h, int_32 tag) {
	HE_t he = memset(alloca(sizeof(*he)), 0, sizeof(*he));

	he->tag = (rpmTag)tag;
	return headerDel(h, he, 0);
}

static int headerNextIterator(HeaderIterator hi, hTAG_t tag, hTYP_t type, hPTR_t * p, hCNT_t c) {
	  HE_t he = memset(alloca(sizeof(*he)), 0, sizeof(*he));
	  headerNext(hi, he, 0);
}

static HeaderIterator headerFreeIterator(HeaderIterator hi) {
	return headerFini(hi);
}

static HeaderIterator headerInitIterator(Header h){
	return headerInit(h);
}

static int headerWrite(void * _fd, Header h, enum hMagic magicp) {
	const char item[] = "Header";
	Header nh = NULL;
	const char * msg = NULL;
	rpmRC rc = rpmpkgWrite(item, _fd, nh, &msg);
	if (rc != RPMRC_OK) {
/*		rpmlog(RPMLOG_ERR, "%s: %s: %s\n", sigtarget, item,
				(msg && *msg ? msg : "write failed\n"));*/
		msg = _free(msg);
		rc = RPMRC_FAIL;
//		goto exit;
	}
	msg = _free(msg);
	return rc;
}

