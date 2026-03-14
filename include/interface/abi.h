#ifndef MORPHL_INTERFACE_ABI_H_
#define MORPHL_INTERFACE_ABI_H_

typedef long long int morphl_int_t;
typedef double morphl_float_t;
typedef struct {
  const char* ptr;
  size_t len;
} morphl_str_t;

typedef void * morphl_block_t;
typedef void * morphl_group_t;

typedef morphl_int_t morphl_exit_code_t;


#endif // MORPHL_INTERFACE_ABI_H_