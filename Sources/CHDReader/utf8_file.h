#ifndef UTF8_FILE_H
#define UTF8_FILE_H

#include <stdio.h>

#ifdef _WIN32
#include <share.h>
#include <stdlib.h>
#include <windows.h>

/* The C runtime's fopen reads the path in the ANSI code page, so UTF-8 names need the wide API. */
static FILE* utf8_fopen(const char* path) {
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  wchar_t* wide = length ? (wchar_t*)malloc((size_t)length * sizeof(wchar_t)) : NULL;
  FILE* file = NULL;
  if (wide && MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, length))
    file = _wfsopen(wide, L"rb", _SH_DENYNO);
  free(wide);
  return file;
}
#define utf8_fseek _fseeki64
#define utf8_ftell _ftelli64
#else
#define utf8_fopen(path) fopen((path), "rb")
#define utf8_fseek fseeko
#define utf8_ftell ftello
#endif

#endif
