/* The same switches Package.swift builds libchdr's miniz.c with: MINIZ_NO_TIME changes mz_zip_archive_file_stat's layout. */
#define MINIZ_NO_DEFLATE_APIS
#define MINIZ_NO_STDIO
#define MINIZ_NO_TIME
#include "zip_reader.h"

#include <stdlib.h>
#include <string.h>

#include "../../Vendor/libchdr/deps/miniz-3.1.2/miniz.h"

int zip_first_file(const void* zip, size_t zip_size, size_t limit, char** name, uint8_t** data, size_t* size) {
  mz_zip_archive archive;
  mz_uint index;
  int found = 0;

  memset(&archive, 0, sizeof(archive));
  if (!zip || !mz_zip_reader_init_mem(&archive, zip, zip_size, 0)) return 0;

  for (index = 0; index < mz_zip_reader_get_num_files(&archive); index++) {
    mz_zip_archive_file_stat stat;
    if (mz_zip_reader_is_file_a_directory(&archive, index)) continue;
    /* The header states the size, so this check comes before anything is allocated for it. */
    if (mz_zip_reader_file_stat(&archive, index, &stat) && stat.m_uncomp_size <= limit) {
      size_t length = 0;
      void* out = mz_zip_reader_extract_to_heap(&archive, index, &length, 0);
      char* copy = (char*)malloc(strlen(stat.m_filename) + 1);
      if (out && copy) {
        strcpy(copy, stat.m_filename);
        *name = copy;
        *data = (uint8_t*)out;
        *size = length;
        found = 1;
      } else {
        free(out);
        free(copy);
      }
    }
    break;
  }

  mz_zip_reader_end(&archive);
  return found;
}
