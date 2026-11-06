/* diagnose.h — say a hard failure where it cannot be lost. See diagnose.c. */

#ifndef VNGRD_DIAGNOSE_H
#define VNGRD_DIAGNOSE_H

#include <stdarg.h>

/* Write a message to stderr AND to /dev/console. Only for failures: the normal
 * "no NV index" path runs on every boot and must stay silent.
 */
void diagnose(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif /* VNGRD_DIAGNOSE_H */
