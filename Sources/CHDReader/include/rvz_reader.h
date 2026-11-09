#ifndef RVZ_READER_H
#define RVZ_READER_H

#include <rc_hash.h>

/* Makes `iterator` read a GameCube .rvz as the plain disc image it holds. Wii images are refused: see rvz_reader.c. */
void rvz_filereader_install(rc_hash_iterator_t* iterator);

/* Non-zero if the last read on this thread hit damaged or missing data. rcheevos can't report read errors,
   so a hash produced in that state must be thrown away. */
int rvz_read_failed(void);

#endif
