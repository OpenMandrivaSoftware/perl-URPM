#include <magic.h>
#include <lzma.h>
#include <zlib.h>

#define kBufferSize (1 << 15)

typedef struct lzma_file {
    uint8_t buf[kBufferSize];
    lzma_stream strm;
    FILE *fp;
    lzma_bool eof;
} lzma_FILE;

typedef enum xFile_e {
    XF_ASCII,
    XF_GZIP,
    XF_LZMA,
    XF_XZ,
    XF_FAIL
} xFile_t;

typedef struct xFile_s {
    xFile_t type;
    lzma_bool eof;
    union {
	gzFile gz;
	lzma_FILE *xz;
    } f;
    FILE *fp;
} xFile;

static lzma_FILE *lzma_open(lzma_ret *lzma_error, FILE *fp, uint64_t memlimit)
{
	lzma_ret *ret = lzma_error;
	lzma_FILE *lzma_file;
	lzma_stream tmp = LZMA_STREAM_INIT;
    
	lzma_file = calloc(1, sizeof(*lzma_file));

	lzma_file->fp = fp;
	lzma_file->eof = 0;
	lzma_file->strm = tmp;

	*ret = lzma_auto_decoder(&lzma_file->strm, memlimit, 0);

	if (*ret != LZMA_OK) {
		(void) fclose(lzma_file->fp);
		free(lzma_file);
		return NULL;
	}
	return lzma_file;
}

static ssize_t lzma_read(lzma_ret *lzma_error, lzma_FILE *lzma_file, void *buf, size_t len)
{
	lzma_ret *ret = lzma_error;
	lzma_bool eof = 0;
    
	if (!lzma_file)
		return -1;
	if (lzma_file->eof)
		return 0;

	lzma_file->strm.next_out = buf;
	lzma_file->strm.avail_out = len;
	for (;;) {
		if (!lzma_file->strm.avail_in) {
			lzma_file->strm.next_in = (uint8_t *)lzma_file->buf;
			lzma_file->strm.avail_in = fread(lzma_file->buf, 1, kBufferSize, lzma_file->fp);
			if (!lzma_file->strm.avail_in)
				eof = 1;
		}
		*ret = lzma_code(&lzma_file->strm, LZMA_RUN);
		if (*ret == LZMA_STREAM_END) {
			lzma_file->eof = 1;
			return len - lzma_file->strm.avail_out;
		}
		if (*ret != LZMA_OK)
			return -1;
		if (!lzma_file->strm.avail_out)
			return len;
		if (eof)
			return -1;
	}
}


static xFile xOpen(const char *path) {
    xFile xF = {XF_FAIL, 0, {NULL}, NULL};
    lzma_ret ret = LZMA_OK;
    const char *message, *tmp;
    magic_t cookie;
    cookie = magic_open(MAGIC_NONE);
    if(!magic_load(cookie, NULL)) {
	message = magic_file(cookie, path);
	if(message == NULL)
	    xF.type = XF_FAIL;
	else if(strstr(message, "gzip compressed"))
	    xF.type = XF_GZIP;
	else if(strstr(message, "xz compressed"))
	    xF.type = XF_XZ;
	else if(strstr(message, "LZMA compressed"))
	    xF.type = XF_LZMA;
	else if(strstr(message, "ASCII"))
	    xF.type = XF_ASCII;
	magic_close(cookie);
    }
    if(xF.type == XF_FAIL && (tmp = rindex(path, '.'))) {
	if(!strcmp(tmp, ".cz") || !strcmp(tmp, ".cz"))
	    xF.type = XF_GZIP;
	else if(!strcmp(tmp, ".xz"))
	    xF.type = XF_XZ;
	else if(!strcmp(tmp, ".lzma"))
	    xF.type = XF_LZMA;
    }

    switch(xF.type) {
	case XF_GZIP:
	    xF.f.gz = gzopen(path, "rb");
	    break;
	case XF_ASCII:
	case XF_LZMA:
	case XF_XZ:
	    xF.fp = fopen(path, "rb");
	    if(xF.type == XF_ASCII) break;	    
	    xF.f.xz = lzma_open(&ret, xF.fp, -1);
	    if(ret != LZMA_OK)
		xF.type = XF_FAIL;
	    break;
	default:
	    break;
    }

    return xF;
}

static int xClose(xFile *xF) {
    int ret = -1;
    switch(xF->type) {
	case XF_GZIP:
	    ret = gzclose(xF->f.gz);
	    break;
	case XF_LZMA:
	case XF_XZ:
    	    lzma_end(&xF->f.xz->strm);
	    free(xF->f.xz);
	case XF_ASCII:
	    ret = fclose(xF->fp);
	    break;
	default:
	    break;
    }
    return ret;
}

static ssize_t xRead(xFile *xF, lzma_ret *ret, void *buf, size_t len) {
    ssize_t sz;
    switch(xF->type) {
	case XF_GZIP:
	    sz = gzread(xF->f.gz, buf, len);
	    xF->eof = gzeof(xF->f.gz);
	    break;
	case XF_LZMA:
	case XF_XZ:
	    sz = lzma_read(ret, xF->f.xz, buf, len);
	    xF->eof = xF->f.xz->eof;
	    break;
	case XF_ASCII:
	    sz = fread(buf, 1, len, xF->fp);
	    xF->eof = feof(xF->fp);
	    break;
	default:
	    break;
    }
    return sz;
}


