#ifndef ZIP_READER_H
#define ZIP_READER_H

#include <stddef.h>
#include <stdint.h>

/* Inflates the first file (not folder) of the zip held at `zip`, `zip_size` bytes, refusing one that decodes to more
   than `limit`. On success returns 1 and sets `name` (as stored, NUL-terminated) and `data`; both are the caller's to
   free(). Returns 0 for a corrupt, over-limit or unsupported archive. */
int zip_first_file(const void* zip, size_t zip_size, size_t limit, char** name, uint8_t** data, size_t* size);

#endif
