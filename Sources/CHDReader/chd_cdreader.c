#include "chd_cdreader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "chd.h"

/* A CD frame in a CHD is 2352 bytes of sector data plus 96 of subcode; DVD "frames" are plain 2048-byte sectors. */
#define CD_FRAME_BYTES 2448
#define DVD_FRAME_BYTES 2048
#define MAX_TRACKS 99
#define GD_HIGH_DENSITY_LBA 45000

typedef struct {
  int is_data;
  int data_offset;      /* where the 2048 user bytes start inside a stored frame */
  int pregap_in_file;
  int32_t pregap;
  uint32_t frames;      /* stored frames, pregap included when it is in the file */
  uint32_t pad;         /* unused frames after the track in the CHD */
  uint32_t chd_frame;   /* index of the track's first stored frame in the CHD */
  int32_t start;        /* disc sector of the first stored frame */
  int32_t first;        /* disc sector where the track proper (index 1) starts */
} track_t;

typedef struct {
  chd_file* chd;
  uint32_t frame_bytes, frames_per_hunk;
  uint8_t* hunk;
  int64_t hunk_number;
  track_t track;
} handle_t;

static int parse_type(const char* type, track_t* t) {
  static const struct { const char* name; int data; int offset; } types[] = {
    { "MODE1", 1, 0 }, { "MODE1_RAW", 1, 16 }, { "MODE2", 1, 8 }, { "MODE2_FORM1", 1, 0 },
    { "MODE2_FORM_MIX", 1, 8 }, { "MODE2_RAW", 1, 24 }, { "MODE2_FORM2", 0, 0 }, { "AUDIO", 0, 0 },
  };
  for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
    if (strcmp(type, types[i].name) == 0) { t->is_data = types[i].data; t->data_offset = types[i].offset; return 1; }
  }
  return 0;
}

/* Reads the index-th track entry of the CD metadata. Returns 1 on success, 0 when there is none or it is malformed. */
static int read_track(chd_file* chd, uint32_t index, track_t* t, int* gdrom) {
  char meta[256], type[256], sub[256], pgtype[256], pgsub[256];
  uint32_t length = 0;
  int number = 0, frames = 0, pad = 0, pregap = 0, postgap = 0, fields = 0;

  /* tokens in the metadata can't be longer than the metadata itself, so the 256-byte buffers can't overflow */
  if (chd_get_metadata(chd, CDROM_TRACK_METADATA2_TAG, index, meta, sizeof(meta) - 1, &length, NULL, NULL) == CHDERR_NONE) {
    meta[length] = 0;
    fields = sscanf(meta, CDROM_TRACK_METADATA2_FORMAT, &number, type, sub, &frames, &pregap, pgtype, pgsub, &postgap) == 8;
  } else if (chd_get_metadata(chd, GDROM_TRACK_METADATA_TAG, index, meta, sizeof(meta) - 1, &length, NULL, NULL) == CHDERR_NONE ||
             chd_get_metadata(chd, GDROM_OLD_METADATA_TAG, index, meta, sizeof(meta) - 1, &length, NULL, NULL) == CHDERR_NONE) {
    meta[length] = 0;
    *gdrom = 1;
    fields = sscanf(meta, GDROM_TRACK_METADATA_FORMAT, &number, type, sub, &frames, &pad, &pregap, pgtype, pgsub, &postgap) == 9;
  } else if (chd_get_metadata(chd, CDROM_TRACK_METADATA_TAG, index, meta, sizeof(meta) - 1, &length, NULL, NULL) == CHDERR_NONE) {
    meta[length] = 0;
    pgtype[0] = 0;
    fields = sscanf(meta, CDROM_TRACK_METADATA_FORMAT, &number, type, sub, &frames) == 4;
  }
  if (!fields || number != (int)index + 1 || frames <= 0 || pregap < 0 || pad < 0 || !parse_type(type, t))
    return 0;

  t->pregap = pregap;
  t->pregap_in_file = pregap > 0 && pgtype[0] == 'V';
  t->frames = (uint32_t)frames;
  t->pad = *gdrom ? (uint32_t)pad : ((uint32_t)frames + 3) / 4 * 4 - (uint32_t)frames;  /* chdman pads CD tracks to 4 frames */
  return 1;
}

/* Where each track sits on the disc, in the same sector numbering ISO 9660 extents use. */
static void layout(track_t* tracks, int count, int gdrom) {
  int32_t position = 0;
  uint32_t chd_frame = 0;
  for (int i = 0; i < count; i++) {
    track_t* t = &tracks[i];
    int32_t in_file = t->pregap_in_file ? t->pregap : 0;
    if (i == 0) position = -in_file;      /* sector 0 is where the first track proper starts */
    else if (!t->pregap_in_file) position += t->pregap;
    t->first = position + in_file;
    if (gdrom && i == 2) t->first = GD_HIGH_DENSITY_LBA;
    t->start = t->first - in_file;
    t->chd_frame = chd_frame;
    position = t->start + (int32_t)t->frames;
    chd_frame += t->frames + t->pad;
  }
}

static void close_track(void* track_handle) {
  handle_t* h = (handle_t*)track_handle;
  if (!h) return;
  if (h->chd) chd_close(h->chd);
  free(h->hunk);
  free(h);
}

static void* open_track(const char* path, uint32_t wanted, const rc_hash_iterator_t* iterator) {
  (void)iterator;
  chd_file* chd = NULL;
  if (chd_open(path, CHD_OPEN_READ, NULL, &chd) != CHDERR_NONE) return NULL;

  handle_t* h = (handle_t*)calloc(1, sizeof(handle_t));
  if (!h) { chd_close(chd); return NULL; }
  h->chd = chd;
  h->hunk_number = -1;

  const chd_header* header = chd_get_header(chd);
  track_t tracks[MAX_TRACKS];
  int count = 0, gdrom = 0;
  memset(tracks, 0, sizeof(tracks));

  if (chd_get_metadata(chd, DVD_METADATA_TAG, 0, NULL, 0, NULL, NULL, NULL) == CHDERR_NONE) {
    h->frame_bytes = DVD_FRAME_BYTES;
    tracks[0].is_data = 1;
    tracks[0].frames = (uint32_t)(header->logicalbytes / DVD_FRAME_BYTES);
    count = 1;
  } else {
    h->frame_bytes = CD_FRAME_BYTES;
    while (count < MAX_TRACKS && read_track(chd, (uint32_t)count, &tracks[count], &gdrom)) count++;
    layout(tracks, count, gdrom);
  }

  int pick = -1;
  for (int i = 0; i < count; i++) {
    if (wanted == RC_HASH_CDTRACK_FIRST_DATA ? (pick < 0 && tracks[i].is_data) :
        wanted == RC_HASH_CDTRACK_LAST ? 1 :
        wanted == RC_HASH_CDTRACK_LARGEST ? (pick < 0 || tracks[i].frames > tracks[pick].frames) :
        wanted == (uint32_t)i + 1)
      pick = i;
  }
  if (pick < 0 || header->hunkbytes == 0 || header->hunkbytes % h->frame_bytes != 0) { close_track(h); return NULL; }

  h->track = tracks[pick];
  h->frames_per_hunk = header->hunkbytes / h->frame_bytes;
  h->hunk = (uint8_t*)malloc(header->hunkbytes);
  if (!h->hunk) { close_track(h); return NULL; }
  return h;
}

static uint32_t first_track_sector(void* track_handle) {
  handle_t* h = (handle_t*)track_handle;
  return h ? (uint32_t)h->track.first : 0;
}

static size_t read_sector(void* track_handle, uint32_t sector, void* buffer, size_t requested_bytes) {
  handle_t* h = (handle_t*)track_handle;
  uint8_t* out = (uint8_t*)buffer;
  size_t total = 0;
  if (!h) return 0;

  for (int64_t lba = sector; requested_bytes > 0; lba++) {
    int64_t index = lba - h->track.start;
    if (index < 0 || index >= (int64_t)h->track.frames) break;

    int64_t frame = (int64_t)h->track.chd_frame + index;
    int64_t hunk = frame / h->frames_per_hunk;
    if (hunk != h->hunk_number) {
      if (chd_read(h->chd, (uint32_t)hunk, h->hunk) != CHDERR_NONE) { h->hunk_number = -1; break; }
      h->hunk_number = hunk;
    }

    size_t count = requested_bytes < 2048 ? requested_bytes : 2048;
    memcpy(out + total, h->hunk + (frame % h->frames_per_hunk) * h->frame_bytes + h->track.data_offset, count);
    total += count;
    requested_bytes -= count;
  }
  return total;
}

void chd_cdreader_install(rc_hash_iterator_t* iterator) {
  rc_hash_cdreader_t* reader = &iterator->callbacks.cdreader;
  reader->open_track = NULL;
  reader->open_track_iterator = open_track;
  reader->read_sector = read_sector;
  reader->close_track = close_track;
  reader->first_track_sector = first_track_sector;
}
