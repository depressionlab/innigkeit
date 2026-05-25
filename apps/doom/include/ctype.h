#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Character classification */
int isdigit(int c);
int isspace(int c);
int isupper(int c);
int islower(int c);
int isalpha(int c);
int isalnum(int c);
int ispunct(int c);
int isprint(int c);

/* Character conversion */
int toupper(int c);
int tolower(int c);

#ifdef __cplusplus
}
#endif
