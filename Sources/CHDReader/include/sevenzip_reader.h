#ifndef SEVENZIP_READER_H
#define SEVENZIP_READER_H

#include <stddef.h>
#include <stdint.h>

/* Builds the CRC tables the 7z code needs. Call once before sevenzip_first_file; it is not thread-safe. */
void sevenzip_init(void);

/* Decodes the first non-empty file of the .7z at `path` (UTF-8). No single allocation may exceed `limit`, which
   also caps the decoded size. On success returns 1 and sets `name` (UTF-16, `name_length` units, not terminated)
   and `data`; both are the caller's to free(). Returns 0 for a corrupt, over-limit or unsupported archive. */
int sevenzip_first_file(const char* path, size_t limit, uint16_t** name, size_t* name_length, uint8_t** data, size_t* size);

#endif
