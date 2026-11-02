#ifndef CHD_CDREADER_H
#define CHD_CDREADER_H

#include <rc_hash.h>

/* Makes `iterator` read disc images from CHD files (CD and DVD) instead of cue/bin. Call after rc_hash_initialize_iterator. */
void chd_cdreader_install(rc_hash_iterator_t* iterator);

#endif
