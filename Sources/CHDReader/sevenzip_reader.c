#include "sevenzip_reader.h"

#include <stdlib.h>
#include <string.h>

#include "7z.h"
#include "7zCrc.h"
#include "utf8_file.h"

#define LOOK_BUFFER_BYTES ((size_t)1 << 18)

typedef struct {
  ISeekInStream vt;
  FILE* file;
} file_stream_t;

static SRes stream_read(ISeekInStreamPtr p, void* buffer, size_t* size) {
  file_stream_t* stream = Z7_CONTAINER_FROM_VTBL(p, file_stream_t, vt);
  *size = fread(buffer, 1, *size, stream->file);
  return ferror(stream->file) ? SZ_ERROR_READ : SZ_OK;
}

static SRes stream_seek(ISeekInStreamPtr p, Int64* position, ESzSeek origin) {
  file_stream_t* stream = Z7_CONTAINER_FROM_VTBL(p, file_stream_t, vt);
  int whence = origin == SZ_SEEK_SET ? SEEK_SET : origin == SZ_SEEK_CUR ? SEEK_CUR : SEEK_END;
  if (utf8_fseek(stream->file, *position, whence) != 0) return SZ_ERROR_READ;
  *position = utf8_ftell(stream->file);
  return *position < 0 ? SZ_ERROR_READ : SZ_OK;
}

/* Headers declare their own sizes, so every allocation is capped: this is what stops a hostile archive. */
typedef struct {
  ISzAlloc vt;
  size_t limit;
} capped_alloc_t;

static void* capped_malloc(ISzAllocPtr p, size_t size) {
  const capped_alloc_t* alloc = Z7_CONTAINER_FROM_VTBL(p, capped_alloc_t, vt);
  return size == 0 || size > alloc->limit ? NULL : malloc(size);
}

static void capped_free(ISzAllocPtr p, void* address) {
  (void)p;
  free(address);
}

void sevenzip_init(void) {
  CrcGenerateTable();
}

int sevenzip_first_file(const char* path, size_t limit, uint16_t** name, size_t* name_length, uint8_t** data, size_t* size) {
  file_stream_t stream;
  capped_alloc_t alloc;
  CLookToRead2 look;
  CSzArEx db;
  UInt32 index;
  int found = 0;

  stream.vt.Read = stream_read;
  stream.vt.Seek = stream_seek;
  stream.file = utf8_fopen(path);
  if (!stream.file) return 0;

  alloc.vt.Alloc = capped_malloc;
  alloc.vt.Free = capped_free;
  alloc.limit = limit;

  LookToRead2_CreateVTable(&look, False);
  look.realStream = &stream.vt;
  look.bufSize = LOOK_BUFFER_BYTES;
  look.buf = (Byte*)malloc(LOOK_BUFFER_BYTES);
  LookToRead2_INIT(&look)
  SzArEx_Init(&db);

  if (look.buf && SzArEx_Open(&db, &look.vt, &alloc.vt, &alloc.vt) == SZ_OK) {
    for (index = 0; index < db.NumFiles; index++) {
      if (SzArEx_IsDir(&db, index) || SzArEx_GetFileSize(&db, index) == 0) continue;

      {
        UInt32 block = 0xFFFFFFFF;
        Byte* output = NULL;
        size_t output_size = 0, offset = 0, processed = 0;
        size_t length = SzArEx_GetFileNameUtf16(&db, index, NULL);  /* includes the terminator */
        uint16_t* utf16 = (uint16_t*)malloc(length * sizeof(uint16_t));

        if (utf16 && SzArEx_Extract(&db, &look.vt, index, &block, &output, &output_size, &offset, &processed, &alloc.vt, &alloc.vt) == SZ_OK) {
          SzArEx_GetFileNameUtf16(&db, index, utf16);
          memmove(output, output + offset, processed);
          *name = utf16;
          *name_length = length - 1;
          *data = output;
          *size = processed;
          found = 1;
        } else {
          free(utf16);
          free(output);
        }
      }
      break;
    }
  }

  SzArEx_Free(&db, &alloc.vt);
  free(look.buf);
  fclose(stream.file);
  return found;
}
