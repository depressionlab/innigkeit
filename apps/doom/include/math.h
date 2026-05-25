#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Mathematical constants */
#define M_PI     3.14159265358979323846
#define M_E      2.71828182845904523536

/* IEEE special values (using GCC/Clang builtins for freestanding) */
#define INFINITY (__builtin_inff())
#define NAN      (__builtin_nanf(""))

/* --- Double-precision functions --- */
double sin(double x);
double cos(double x);
double sqrt(double x);
double fabs(double x);
double floor(double x);
double ceil(double x);
double atan2(double y, double x);
double log(double x);
double exp(double x);
double pow(double x, double y);

/* --- Single-precision functions --- */
float sinf(float x);
float cosf(float x);
float sqrtf(float x);
float fabsf(float x);
float atan2f(float y, float x);

#ifdef __cplusplus
}
#endif
