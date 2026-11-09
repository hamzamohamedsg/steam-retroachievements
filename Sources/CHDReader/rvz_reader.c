/* Reads the plain disc out of an RVZ, following Dolphin's docs/WiaAndRvz.md.
 *
 * shortcut: GameCube only. rcheevos hashes a Wii partition's encrypted bytes, but an RVZ stores them decrypted with
 * the hash blocks removed, so a Wii reader would have to rebuild the hash tree and re-encrypt every block. Upgrade
 * once that can be checked against real Wii RVZs; until then Wii keeps the name match instead of risking a wrong hash.
 *
 * shortcut: the SHA-1s in the headers aren't checked. A damaged file gets caught by the size checks or by the decoders,
 * or else hashes as damaged, the same as a damaged .iso would.
 */
#include "rvz_reader.h"

#include <stdlib.h>
#include <string.h>

#include "Lzma2Dec.h"
#include "LzmaDec.h"
#include "../../Vendor/libchdr/deps/zstd-1.5.7/zstd.h"
#include "utf8_file.h"

enum { HEAD_BYTES = 0x48, DISC_BYTES = 0xDC, DHEAD_BYTES = 0x80 };
enum { RAW_ENTRY_BYTES = 24, GROUP_ENTRY_BYTES = 12 };
enum { METHOD_NONE = 0, METHOD_LZMA = 3, METHOD_LZMA2 = 4, METHOD_ZSTD = 5 };
enum { DISC_GAMECUBE = 1 };

#define SUPPORTED_VERSION 0x01000000u
#define SECTOR_BYTES 0x8000u
#define MIN_CHUNK_BYTES SECTOR_BYTES
#define MULTIPLE_CHUNK_BYTES 0x200000u
#define MAX_CHUNK_BYTES (64u << 20)
#define MAX_RAW_ENTRIES 4096u
#define MAX_GROUPS (1u << 24)
#define COMPRESSED_FLAG 0x80000000u
#define NO_GROUP ((uint32_t)-1)

#define JUNK_WORDS 521
#define JUNK_BYTES (JUNK_WORDS * 4)
#define JUNK_SEED_WORDS 17
#define JUNK_SEED_BYTES (JUNK_SEED_WORDS * 4)

typedef struct {
  uint64_t offset, size;
  uint32_t group, groups;
} raw_entry_t;

typedef struct {
  uint32_t offset4, size, packed;
} group_entry_t;

typedef struct {
  FILE* file;
  uint64_t file_size, iso_size, position;
  uint32_t chunk, method, raw_count, group_count;
  uint8_t props[7];
  uint8_t dhead[DHEAD_BYTES];
  raw_entry_t* raw;
  group_entry_t* groups;
  uint8_t* input, *packed, *chunk_data;
  uint32_t cached_group;
} rvz_t;

static _Thread_local int read_failed;

int rvz_read_failed(void) {
  return read_failed;
}

static uint32_t be32(const uint8_t* p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint64_t be64(const uint8_t* p) {
  return (uint64_t)be32(p) << 32 | be32(p + 4);
}

static int read_at(rvz_t* h, uint64_t offset, void* out, size_t size) {
  if (offset > h->file_size || size > h->file_size - offset) return 0;
  return utf8_fseek(h->file, (int64_t)offset, SEEK_SET) == 0 && fread(out, 1, size, h->file) == size;
}

static void* sz_malloc(ISzAllocPtr p, size_t size) { (void)p; return size ? malloc(size) : NULL; }
static void sz_free(ISzAllocPtr p, void* address) { (void)p; free(address); }
static const ISzAlloc sz_alloc = { sz_malloc, sz_free };

/* Every caller knows the exact decoded size, so anything else means the data is damaged. */
static int decompress(const rvz_t* h, uint32_t method, const uint8_t* in, size_t in_size, uint8_t* out, size_t out_size) {
  SizeT produced = out_size, consumed = in_size;
  ELzmaStatus status;
  size_t result;

  switch (method) {
    case METHOD_NONE:
      if (in_size != out_size) return 0;
      memcpy(out, in, out_size);
      return 1;
    case METHOD_ZSTD:
      result = ZSTD_decompress(out, out_size, in, in_size);
      return !ZSTD_isError(result) && result == out_size;
    case METHOD_LZMA:
      return LzmaDecode(out, &produced, in, &consumed, h->props, 5, LZMA_FINISH_ANY, &status, &sz_alloc) == SZ_OK && produced == out_size;
    case METHOD_LZMA2:
      return Lzma2Decode(out, &produced, in, &consumed, h->props[0], LZMA_FINISH_ANY, &status, &sz_alloc) == SZ_OK && produced == out_size;
    default:
      return 0;
  }
}

static void junk_forward(uint32_t* buffer) {
  int i;
  for (i = 0; i < 32; i++) buffer[i] ^= buffer[i + JUNK_WORDS - 32];
  for (i = 32; i < JUNK_WORDS; i++) buffer[i] ^= buffer[i - 32];
}

/* Regenerates disc padding from its seed. `offset` is where `out` sits on the disc. */
static void junk_fill(uint8_t* out, size_t size, const uint8_t* seed, uint64_t offset) {
  static const int shifts[4] = { 24, 18, 8, 0 };  /* 18, not 16: the spec calls this out */
  uint32_t buffer[JUNK_WORDS];
  size_t position = (size_t)(offset % SECTOR_BYTES), i;

  for (i = 0; i < JUNK_SEED_WORDS; i++) buffer[i] = be32(seed + i * 4);
  for (i = JUNK_SEED_WORDS; i < JUNK_WORDS; i++)
    buffer[i] = (buffer[i - 17] << 23) ^ (buffer[i - 16] >> 9) ^ buffer[i - 1];
  for (i = 0; i < 4; i++) junk_forward(buffer);

  for (; position >= JUNK_BYTES; position -= JUNK_BYTES) junk_forward(buffer);
  for (i = 0; i < size; i++) {
    out[i] = (uint8_t)(buffer[position / 4] >> shifts[position % 4]);
    if (++position == JUNK_BYTES) {
      junk_forward(buffer);
      position = 0;
    }
  }
}

/* Undoes RVZ packing: runs of stored bytes and of seeded padding, which must add up to exactly `out_size`. */
static int unpack(const uint8_t* in, size_t in_size, uint8_t* out, size_t out_size, uint64_t offset) {
  size_t read_position = 0, written = 0;

  while (read_position < in_size) {
    uint32_t header, count;

    if (in_size - read_position < 4) return 0;
    header = be32(in + read_position);
    read_position += 4;
    count = header & 0x7FFFFFFFu;
    if (count > out_size - written) return 0;

    if (header & 0x80000000u) {
      if (in_size - read_position < JUNK_SEED_BYTES) return 0;
      junk_fill(out + written, count, in + read_position, offset + written);
      read_position += JUNK_SEED_BYTES;
    } else {
      if (in_size - read_position < count) return 0;
      memcpy(out + written, in + read_position, count);
      read_position += count;
    }
    written += count;
  }
  return written == out_size;
}

/* Puts group `index` into h->chunk_data; `offset` is where it sits on the disc and `size` is how much it decodes to. */
static int load_group(rvz_t* h, uint32_t index, uint64_t offset, uint32_t size) {
  const group_entry_t* group = &h->groups[index];
  uint32_t stored = group->size & ~COMPRESSED_FLAG;
  uint32_t method = (group->size & COMPRESSED_FLAG) ? h->method : (uint32_t)METHOD_NONE;

  if (h->cached_group == index) return 1;
  h->cached_group = NO_GROUP;

  if (stored == 0) {
    memset(h->chunk_data, 0, size);
  } else {
    if (stored > h->chunk * 2 + 0x10000u || group->packed > h->chunk * 2) return 0;
    if (!read_at(h, (uint64_t)group->offset4 * 4, h->input, stored)) return 0;
    if (group->packed) {
      if (!decompress(h, method, h->input, stored, h->packed, group->packed)) return 0;
      if (!unpack(h->packed, group->packed, h->chunk_data, size, offset)) return 0;
    } else if (!decompress(h, method, h->input, stored, h->chunk_data, size)) {
      return 0;
    }
  }
  h->cached_group = index;
  return 1;
}

static size_t rvz_read(void* handle, void* buffer, size_t requested) {
  rvz_t* h = (rvz_t*)handle;
  uint8_t* out = (uint8_t*)buffer;
  size_t total = 0;

  while (total < requested && h->position < h->iso_size) {
    const raw_entry_t* entry = NULL;
    uint64_t chunk_index, chunk_offset, chunk_start, remaining;
    uint32_t chunk_size, i;
    size_t in_chunk, count;

    for (i = 0; i < h->raw_count && !entry; i++) {
      if (h->position >= h->raw[i].offset && h->position - h->raw[i].offset < h->raw[i].size) entry = &h->raw[i];
    }
    if (!entry) { read_failed = 1; break; }

    chunk_index = (h->position - entry->offset) / h->chunk;
    chunk_offset = (h->position - entry->offset) % h->chunk;
    chunk_start = entry->offset + chunk_index * h->chunk;
    remaining = entry->size - chunk_index * h->chunk;
    chunk_size = remaining < h->chunk ? (uint32_t)remaining : h->chunk;

    if (chunk_index >= entry->groups || !load_group(h, entry->group + (uint32_t)chunk_index, chunk_start, chunk_size)) {
      read_failed = 1;
      break;
    }

    in_chunk = chunk_size - (size_t)chunk_offset;
    count = requested - total < in_chunk ? requested - total : in_chunk;
    if (count > h->iso_size - h->position) count = (size_t)(h->iso_size - h->position);
    memcpy(out + total, h->chunk_data + chunk_offset, count);

    /* The disc's first bytes live in wia_disc_t, not in the group that covers them. */
    if (h->position < DHEAD_BYTES) {
      size_t head = DHEAD_BYTES - (size_t)h->position;
      memcpy(out + total, h->dhead + h->position, head < count ? head : count);
    }

    h->position += count;
    total += count;
  }
  return total;
}

static void rvz_close(void* handle) {
  rvz_t* h = (rvz_t*)handle;
  if (!h) return;
  if (h->file) fclose(h->file);
  free(h->raw);
  free(h->groups);
  free(h->input);
  free(h->packed);
  free(h->chunk_data);
  free(h);
}

static void rvz_seek(void* handle, int64_t offset, int origin) {
  rvz_t* h = (rvz_t*)handle;
  int64_t base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? (int64_t)h->position : (int64_t)h->iso_size;
  if (base + offset >= 0) h->position = (uint64_t)(base + offset);
}

static int64_t rvz_tell(void* handle) {
  return (int64_t)((rvz_t*)handle)->position;
}

/* Reads a table, which is compressed with the file's method, and returns it decoded (NULL on damage). */
static uint8_t* read_table(rvz_t* h, uint64_t offset, uint32_t stored, size_t size) {
  uint8_t* in = (uint8_t*)malloc(stored ? stored : 1);
  uint8_t* out = (uint8_t*)malloc(size ? size : 1);
  int ok = in && out && read_at(h, offset, in, stored) && decompress(h, h->method, in, stored, out, size);
  free(in);
  if (!ok) {
    free(out);
    return NULL;
  }
  return out;
}

static int chunk_size_is_valid(uint32_t chunk) {
  if (chunk < MIN_CHUNK_BYTES || chunk > MAX_CHUNK_BYTES) return 0;
  return chunk < MULTIPLE_CHUNK_BYTES ? (chunk & (chunk - 1)) == 0 : chunk % MULTIPLE_CHUNK_BYTES == 0;
}

static int load_tables(rvz_t* h) {
  uint8_t header[HEAD_BYTES + DISC_BYTES];
  const uint8_t* disc = header + HEAD_BYTES;
  uint8_t* table;
  uint32_t props_size, i;

  if (utf8_fseek(h->file, 0, SEEK_END) != 0) return 0;
  h->file_size = (uint64_t)utf8_ftell(h->file);
  if (!read_at(h, 0, header, sizeof(header))) return 0;

  if (memcmp(header, "RVZ\x01", 4) != 0 || be32(header + 0x08) > SUPPORTED_VERSION || be32(header + 0x0C) < DISC_BYTES) return 0;
  h->iso_size = be64(header + 0x24);

  h->method = be32(disc + 0x04);
  h->chunk = be32(disc + 0x0C);
  h->raw_count = be32(disc + 0xB4);
  h->group_count = be32(disc + 0xC4);
  props_size = disc[0xD4];
  if (be32(disc) != DISC_GAMECUBE || be32(disc + 0x90) != 0 || h->iso_size == 0 || !chunk_size_is_valid(h->chunk)) return 0;
  if (h->raw_count == 0 || h->raw_count > MAX_RAW_ENTRIES || h->group_count == 0 || h->group_count > MAX_GROUPS) return 0;

  if (props_size > sizeof(h->props)) return 0;
  memcpy(h->props, disc + 0xD5, props_size);
  switch (h->method) {
    case METHOD_NONE: case METHOD_ZSTD: break;
    case METHOD_LZMA: if (props_size != 5) return 0; break;
    case METHOD_LZMA2: if (props_size != 1 || h->props[0] > 40) return 0; break;
    default: return 0;
  }
  memcpy(h->dhead, disc + 0x10, DHEAD_BYTES);

  table = read_table(h, be64(disc + 0xB8), be32(disc + 0xC0), (size_t)h->raw_count * RAW_ENTRY_BYTES);
  if (!table) return 0;
  h->raw = (raw_entry_t*)malloc((size_t)h->raw_count * sizeof(raw_entry_t));
  for (i = 0; h->raw && i < h->raw_count; i++) {
    const uint8_t* p = table + (size_t)i * RAW_ENTRY_BYTES;
    uint64_t offset = be64(p), rounded = offset & ~(uint64_t)(SECTOR_BYTES - 1);
    h->raw[i].offset = rounded;
    h->raw[i].size = be64(p + 8) + (offset - rounded);  /* the spec's rule for the first entry, which starts at 0x80 */
    h->raw[i].group = be32(p + 16);
    h->raw[i].groups = be32(p + 20);
    if (h->raw[i].group > h->group_count || h->raw[i].groups > h->group_count - h->raw[i].group) {
      free(table);
      return 0;
    }
  }
  free(table);
  if (!h->raw) return 0;

  table = read_table(h, be64(disc + 0xC8), be32(disc + 0xD0), (size_t)h->group_count * GROUP_ENTRY_BYTES);
  if (!table) return 0;
  h->groups = (group_entry_t*)malloc((size_t)h->group_count * sizeof(group_entry_t));
  for (i = 0; h->groups && i < h->group_count; i++) {
    const uint8_t* p = table + (size_t)i * GROUP_ENTRY_BYTES;
    h->groups[i].offset4 = be32(p);
    h->groups[i].size = be32(p + 4);
    h->groups[i].packed = be32(p + 8);
  }
  free(table);
  if (!h->groups) return 0;

  h->input = (uint8_t*)malloc((size_t)h->chunk * 2 + 0x10000u);
  h->packed = (uint8_t*)malloc((size_t)h->chunk * 2);
  h->chunk_data = (uint8_t*)malloc(h->chunk);
  return h->input && h->packed && h->chunk_data;
}

static void* rvz_open(const char* path) {
  rvz_t* h = (rvz_t*)calloc(1, sizeof(rvz_t));
  read_failed = 0;
  if (!h) return NULL;
  h->cached_group = NO_GROUP;
  h->file = utf8_fopen(path);
  if (!h->file || !load_tables(h)) {
    rvz_close(h);
    return NULL;
  }
  return h;
}

void rvz_filereader_install(rc_hash_iterator_t* iterator) {
  rc_hash_filereader_t* reader = &iterator->callbacks.filereader;
  reader->open = rvz_open;
  reader->seek = rvz_seek;
  reader->tell = rvz_tell;
  reader->read = rvz_read;
  reader->close = rvz_close;
}
