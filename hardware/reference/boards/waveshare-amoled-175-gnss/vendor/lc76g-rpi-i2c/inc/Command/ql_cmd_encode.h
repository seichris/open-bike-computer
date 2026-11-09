#ifndef __QL_CMD_ENCODE_H__
#define __QL_CMD_ENCODE_H__
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

int32_t Ql_Get_Command_Checksum(int8_t* buffer, int32_t buffer_len);

#endif