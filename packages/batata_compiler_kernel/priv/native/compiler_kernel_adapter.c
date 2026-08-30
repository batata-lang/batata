#include "mlir-c/Beaver/CompilerKernel.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef BATATA_KERNEL_IDENTITY
#error "BATATA_KERNEL_IDENTITY must be defined"
#endif

#if defined(_WIN32)
#define BATATA_KERNEL_EXPORT __declspec(dllexport)
#else
#define BATATA_KERNEL_EXPORT __attribute__((visibility("default")))
#endif

enum BatataTargetKind {
  BATATA_TARGET_ARITH_CONSTANT = 1,
  BATATA_TARGET_ARITH_ADDI = 2,
  BATATA_TARGET_ARITH_SUBI = 3,
  BATATA_TARGET_ARITH_MULI = 4,
  BATATA_TARGET_ARITH_DIVSI = 5,
  BATATA_TARGET_ARITH_REMSI = 6,
  BATATA_TARGET_ARITH_CMPI = 7,
  BATATA_TARGET_ARITH_EXTUI = 8,
  BATATA_TARGET_SCF_YIELD = 9,
  BATATA_TARGET_FUNC_CALL = 10,
  BATATA_RUNTIME_TERM_EQ = 11,
  BATATA_RUNTIME_BINARY_PART = 12,
  BATATA_RUNTIME_LIST_CONS = 13,
  BATATA_RUNTIME_BINARY_FROM_LIST = 14,
  BATATA_TARGET_ARITH_TRUNCI = 15,
  BATATA_TARGET_SCF_IF = 16,
  BATATA_TARGET_FUNC_RETURN = 17,
  BATATA_TARGET_FUNC_FUNC = 18,
  BATATA_RUNTIME_RUNTIME_CREATE = 19,
  BATATA_RUNTIME_RUNTIME_ENTER = 20,
  BATATA_RUNTIME_RUNTIME_LEAVE = 21,
  BATATA_RUNTIME_RUNTIME_DESTROY = 22,
  BATATA_RUNTIME_RESULT_CREATE = 23,
  BATATA_RUNTIME_RESULT_DESTROY = 24,
  BATATA_RUNTIME_RESULT_ROOT_KIND = 25,
  BATATA_RUNTIME_RESULT_ROOT_WORD = 26,
  BATATA_RUNTIME_RESULT_EXCEPTION_KIND = 27,
  BATATA_RUNTIME_RESULT_EXCEPTION_REASON = 28,
  BATATA_RUNTIME_RESULT_TERM_KIND = 29,
  BATATA_RUNTIME_RESULT_ATOM_NAME = 30,
  BATATA_RUNTIME_RESULT_TERM_LENGTH = 31,
  BATATA_RUNTIME_RESULT_TERM_GET = 32,
  BATATA_RUNTIME_TERM_EXPORT = 33,
  BATATA_RUNTIME_TERM_IMPORT = 34,
  BATATA_RUNTIME_EXPORTED_CLONE = 35,
  BATATA_RUNTIME_EXPORTED_DESTROY = 36,
  BATATA_RUNTIME_EXPORTED_LENGTH = 37,
  BATATA_RUNTIME_EXPORTED_GET = 38,
  BATATA_RUNTIME_HANDLE_EXPORT = 39,
  BATATA_RUNTIME_HANDLE_DESTROY = 40,
  BATATA_RUNTIME_PROCESS_TABLE_RESET = 41,
  BATATA_RUNTIME_SELF = 42,
  BATATA_RUNTIME_SEND = 43,
  BATATA_RUNTIME_RECEIVE = 44,
  BATATA_RUNTIME_MAILBOX_CLEAR = 45,
  BATATA_RUNTIME_SPAWN = 46,
  BATATA_RUNTIME_SCHEDULE_NEXT = 47,
  BATATA_RUNTIME_CURRENT_ENTRY = 48,
  BATATA_RUNTIME_PROCESS_DONE = 49,
  BATATA_RUNTIME_PROCESS_EXIT = 50,
  BATATA_RUNTIME_PROCESS_EXIT_REASON = 51,
  BATATA_RUNTIME_PROCESS_TRAP_EXIT = 52,
  BATATA_RUNTIME_LINK = 53,
  BATATA_RUNTIME_UNLINK = 54,
  BATATA_RUNTIME_EXIT = 55,
  BATATA_RUNTIME_MONITOR = 56,
  BATATA_RUNTIME_DEMONITOR = 57,
  BATATA_RUNTIME_PROCESSES_RUNNABLE = 58,
  BATATA_RUNTIME_PROCESS_RESULT = 59,
  BATATA_RUNTIME_CONT_SAVE = 60,
  BATATA_RUNTIME_RECEIVE_CONT_SAVE = 61,
  BATATA_RUNTIME_CONT_PENDING = 62,
  BATATA_RUNTIME_CONT_ACTIVE = 63,
  BATATA_RUNTIME_CONT_CLEAR = 64,
  BATATA_RUNTIME_CONT_LOAD_ARG = 65,
  BATATA_RUNTIME_CONT_LOAD_ACC = 66,
  BATATA_RUNTIME_CONT_LOAD_CURSOR = 67,
  BATATA_RUNTIME_CLOCK_INIT = 68,
  BATATA_RUNTIME_CLOCK_TICK = 69,
  BATATA_RUNTIME_YIELD_MARK = 70,
  BATATA_RUNTIME_MAILBOX_LEN = 71,
  BATATA_RUNTIME_MAILBOX_PEEK = 72,
  BATATA_RUNTIME_MAILBOX_REMOVE = 73,
  BATATA_RUNTIME_NIL = 74,
  BATATA_RUNTIME_MONOTONIC_TIME = 75,
  BATATA_RUNTIME_RECEIVE_START = 76,
  BATATA_RUNTIME_RECEIVE_START_SET = 77,
  BATATA_RUNTIME_NATIVE_TIME = 78,
  BATATA_RUNTIME_UNIQUE_INTEGER = 79,
  BATATA_RUNTIME_TO_INT = 80,
  BATATA_RUNTIME_TERM_EQ_LOOSE = 81,
  BATATA_RUNTIME_LIST_FLATTEN = 82,
  BATATA_RUNTIME_LIST_HEAD = 83,
  BATATA_RUNTIME_LIST_TAIL = 84,
  BATATA_RUNTIME_LIST_GET = 85,
  BATATA_RUNTIME_LIST_LENGTH = 86,
  BATATA_RUNTIME_TUPLE_GET = 87,
  BATATA_RUNTIME_TUPLE_LENGTH = 88,
  BATATA_RUNTIME_MAP_FETCH = 89,
  BATATA_RUNTIME_MAP_PUT = 90,
  BATATA_RUNTIME_MAP_LENGTH = 91,
  BATATA_RUNTIME_MAPSET_FROM_LIST = 92,
  BATATA_RUNTIME_MAPSET_MEMBER = 93,
  BATATA_RUNTIME_MAPSET_PUT = 94,
  BATATA_RUNTIME_IODATA_TO_BINARY = 96,
  BATATA_RUNTIME_FLOAT_LIT = 97,
  BATATA_RUNTIME_STRING_TO_FLOAT = 98,
  BATATA_RUNTIME_STRING_TO_ATOM = 99,
  BATATA_RUNTIME_STRING_TO_EXISTING_ATOM = 100,
  BATATA_RUNTIME_FLOAT_TO_BINARY_SHORT = 101,
  BATATA_RUNTIME_BINARY_LENGTH = 102,
  BATATA_RUNTIME_BINARY_GET = 103,
  BATATA_RUNTIME_BINARY_SLICE = 104,
  BATATA_RUNTIME_BINARY_UTF8_GET = 105,
  BATATA_RUNTIME_BINARY_UTF8_WIDTH = 106,
  BATATA_RUNTIME_BINARY_UTF8_LENGTH = 107,
  BATATA_RUNTIME_STRING_PRINTABLE = 108,
  BATATA_RUNTIME_BINARY_QUOTE = 109,
  BATATA_RUNTIME_BINARY_ENCODE16 = 110,
  BATATA_RUNTIME_BINARY_DECODE16 = 111,
  BATATA_RUNTIME_INT_TO_STRING = 112,
  BATATA_RUNTIME_INT_TO_STRING_BASE = 113,
  BATATA_RUNTIME_INT_TO_HEX = 114,
  BATATA_RUNTIME_STRING_TO_INT = 115,
  BATATA_RUNTIME_FILE_READ = 116,
  BATATA_RUNTIME_FILE_READ_LINES = 117,
  BATATA_RUNTIME_ENUMERABLE_COUNT = 118,
  BATATA_RUNTIME_ENUMERABLE_TO_LIST = 119,
  BATATA_RUNTIME_ENUMERABLE_INTO_MAP = 120,
  BATATA_RUNTIME_ENUMERABLE_INTERSPERSE = 121,
  BATATA_RUNTIME_ENUMERABLE_TO_LIST_RANGE = 122,
  BATATA_RUNTIME_ENUMERABLE_REDUCE = 123,
  BATATA_RUNTIME_ENUMERABLE_REDUCE_C = 124,
  BATATA_RUNTIME_ENUMERABLE_REDUCE_RANGE = 125,
  BATATA_RUNTIME_ENUMERABLE_REDUCE_FUN = 126,
  BATATA_RUNTIME_ENUMERABLE_MAP_FUN = 127,
  BATATA_RUNTIME_ENUMERABLE_MAP_TERM_FUN = 128,
  BATATA_RUNTIME_ENUMERABLE_MAP_TERM_FUN_C = 129,
  BATATA_RUNTIME_ENUMERABLE_FLAT_MAP_TERM_FUN = 130,
  BATATA_RUNTIME_STREAM_FILTER = 131,
  BATATA_RUNTIME_STREAM_TAKE = 132,
  BATATA_RUNTIME_STREAM_DROP = 133,
  BATATA_RUNTIME_FUN_ARITY = 134,
  BATATA_RUNTIME_FUN_RESULT_MODE = 135,
  BATATA_RUNTIME_PROCESS_WAIT = 136,
  BATATA_RUNTIME_WORKER_RUN = 137,
  BATATA_RUNTIME_CATCH_VALUE = 138,
  BATATA_RUNTIME_THROW = 139,
  BATATA_RUNTIME_RAISE = 140,
  BATATA_TARGET_ARITH_SHLI = 141,
  BATATA_RUNTIME_IS_INTEGER = 142,
  BATATA_RUNTIME_IS_FLOAT = 143,
  BATATA_RUNTIME_IS_ATOM = 144,
  BATATA_RUNTIME_IS_BINARY = 145,
  BATATA_RUNTIME_IS_LIST = 146,
  BATATA_RUNTIME_IS_TUPLE = 147,
  BATATA_RUNTIME_IS_MAP = 148,
  BATATA_AGGREGATE_LIST = 149,
  BATATA_RUNTIME_TUPLE_FROM_LIST = 150,
  BATATA_RUNTIME_MAP_FROM_LIST = 151,
  BATATA_RUNTIME_MAKE_FUN = 152,
  BATATA_RUNTIME_MAKE_FUN_WITH_ARITY = 153,
  BATATA_RUNTIME_MAKE_FUN_WITH_SIGNATURE = 154,
  BATATA_RUNTIME_FUN_IDX = 155,
  BATATA_RUNTIME_FUN_ENV = 156,
  BATATA_TARGET_FN_DISPATCH = 157,
  BATATA_TARGET_FUNC_CONSTANT = 158,
  BATATA_TARGET_LLVM_ALLOCA = 159,
  BATATA_TARGET_LLVM_INTTOPTR = 160,
  BATATA_TARGET_LLVM_CALL = 161,
  BATATA_RUNTIME_JMP_BUF_SIZE = 162,
  BATATA_RUNTIME_TRY_PUSH = 163,
  BATATA_RUNTIME_SETJMP_ADDR = 164,
  BATATA_RUNTIME_TRY_POP = 165,
};

enum BatataStructuralLimit {
  BATATA_LIMIT_VALUES = 1,
  BATATA_LIMIT_REGIONS = 2,
};

#define BATATA_MAX_VALUES 8

extern int64_t batata_kernel_pattern_accept(int64_t actual_operands,
                                             int64_t actual_results,
                                             int64_t expected_operands,
                                             int64_t expected_results);
extern int64_t batata_kernel_target_length(int64_t kind);
extern int64_t batata_kernel_target_word(int64_t kind, int64_t index);
extern int64_t batata_kernel_cmp_predicate(int64_t length, int64_t word);
extern int64_t batata_kernel_runtime_arity(int64_t kind);
extern int64_t batata_kernel_structural_limit(int64_t kind);
extern int64_t batata_kernel_term_type_accept(int64_t length,
                                               int64_t reversed_tail);
extern int64_t batata_kernel_aggregate_accept(int64_t kind, int64_t arity);
extern int64_t batata_kernel_function_value_accept(
    int64_t kind, int64_t operands, int64_t arity, int64_t result_mode,
    int64_t env_len);
extern int64_t batata_kernel_try_accept(int64_t operands, int64_t results,
                                        int64_t regions,
                                        int64_t body_arguments,
                                        int64_t catch_arguments);
extern int64_t batata_kernel_pattern_count(void);
extern int64_t batata_kernel_pattern_namespace_length(void);
extern int64_t batata_kernel_pattern_namespace_word(int64_t index);
extern int64_t batata_kernel_pattern_root_length(int64_t pattern);
extern int64_t batata_kernel_pattern_root_word(int64_t pattern, int64_t index);
extern int64_t batata_kernel_pattern_target(int64_t pattern);
extern int64_t batata_kernel_pattern_action(int64_t pattern);
extern int64_t batata_kernel_rewrite(int64_t pattern);

typedef struct {
  char name[96];
  intptr_t name_length;
  char root[80];
  intptr_t root_length;
  int64_t pattern_id;
  int64_t target_kind;
  MlirBeaverCompilerKernelRewriteFn rewrite;
} BatataPattern;

#if defined(_MSC_VER)
#define BATATA_THREAD_LOCAL __declspec(thread)
#else
#define BATATA_THREAD_LOCAL _Thread_local
#endif

typedef struct {
  const MlirBeaverCompilerKernelHostAPI *host;
  MlirOperation operation;
  intptr_t n_operands;
  MlirValue *operands;
  MlirConversionPatternRewriter rewriter;
  MlirTypeConverter type_converter;
  MlirStringCallback diagnostic;
  void *diagnostic_user_data;
  int failed;
  MlirStringRef builder_name;
  char builder_name_storage[80];
  MlirLocation builder_location;
  MlirValue builder_operands[BATATA_MAX_VALUES];
  MlirType builder_results[BATATA_MAX_VALUES];
  MlirNamedAttribute builder_attributes[BATATA_MAX_VALUES];
  intptr_t builder_operand_count;
  intptr_t builder_result_count;
  intptr_t builder_attribute_count;
} BatataInvocation;

static BATATA_THREAD_LOCAL BatataInvocation *current_invocation;

static MlirLogicalResult report_failure(MlirStringCallback diagnostic,
                                        void *user_data,
                                        const char *message,
                                        intptr_t length) {
  if (diagnostic)
    diagnostic(mlirStringRefCreate(message, length), user_data);
  return mlirLogicalResultFailure();
}

#define BATATA_FAIL(diagnostic, user_data, message)                            \
  report_failure((diagnostic), (user_data), (message), sizeof(message) - 1)

static void decode_word(uint32_t word, char *output, intptr_t count) {
  for (intptr_t index = 0; index < count; ++index)
    output[index] = (char)((word >> (index * 8)) & 0xffu);
}

static MlirLogicalResult target_name(int64_t kind, char *storage,
                                     intptr_t capacity, MlirStringRef *name,
                                     MlirStringCallback diagnostic,
                                     void *diagnostic_user_data) {
  int64_t length = batata_kernel_target_length(kind);
  if (length <= 0 || length > capacity)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata target length is outside the ABI buffer");

  for (int64_t offset = 0; offset < length; offset += 4) {
    int64_t word = batata_kernel_target_word(kind, offset / 4);
    if (word < 0 || word > UINT32_MAX)
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata target word is invalid");

    int64_t remaining = length - offset;
    decode_word((uint32_t)word, storage + offset, remaining < 4 ? remaining : 4);
  }

  *name = mlirStringRefCreate(storage, length);
  return mlirLogicalResultSuccess();
}

static MlirLogicalResult validate_shape(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t converted_operands, intptr_t expected_operands,
    intptr_t expected_results, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  intptr_t source_operands;
  intptr_t source_results;

  if (mlirLogicalResultIsFailure(host->operationCounts(
          operation, &source_operands, &source_results, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (source_operands != converted_operands ||
      batata_kernel_pattern_accept(source_operands, source_results,
                                   expected_operands, expected_results) != 1)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata source rejected the operation shape");

  return mlirLogicalResultSuccess();
}

static MlirLogicalResult source_result_type(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    MlirTypeConverter type_converter, MlirType *converted_type,
    MlirStringCallback diagnostic, void *diagnostic_user_data) {
  MlirValue source_result;
  MlirType source_type;

  if (mlirLogicalResultIsFailure(host->operationResult(
          operation, 0, &source_result, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->valueType(
          source_result, &source_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->convertType(
          type_converter, source_type, converted_type, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return mlirLogicalResultSuccess();
}

static MlirLogicalResult source_result_types(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    MlirTypeConverter type_converter, MlirType *converted_types,
    intptr_t capacity, intptr_t *count, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  intptr_t source_operands;
  intptr_t source_results;
  if (!converted_types || !count || capacity < 0 ||
      mlirLogicalResultIsFailure(host->operationCounts(
          operation, &source_operands, &source_results, diagnostic,
          diagnostic_user_data)) ||
      source_results < 0 || source_results > capacity)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata result list exceeds its closed ABI limit");

  (void)source_operands;
  for (intptr_t index = 0; index < source_results; ++index) {
    MlirValue source_result;
    MlirType source_type;
    if (mlirLogicalResultIsFailure(host->operationResult(
            operation, index, &source_result, diagnostic,
            diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->valueType(
            source_result, &source_type, diagnostic, diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->convertType(
            type_converter, source_type, &converted_types[index], diagnostic,
            diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  *count = source_results;
  return mlirLogicalResultSuccess();
}

static MlirLogicalResult create_and_replace(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirStringRef target,
    MlirLocation location, intptr_t n_result_types,
    const MlirType *result_types, intptr_t n_attributes,
    const MlirNamedAttribute *attributes, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      target,
      location,
      n_operands,
      operands,
      n_result_types,
      result_types,
      n_attributes,
      attributes,
  };

  MlirOperation replacement;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &descriptor, &replacement, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (n_result_types == 0)
    return host->replaceOperationWithValues(rewriter, operation, 0, NULL,
                                            diagnostic, diagnostic_user_data);

  MlirValue replacement_result;
  if (n_result_types != 1 ||
      mlirLogicalResultIsFailure(host->operationResult(
          replacement, 0, &replacement_result, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(
      rewriter, operation, 1, &replacement_result, diagnostic,
      diagnostic_user_data);
}

static MlirLogicalResult create_runtime_call(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation anchor,
    MlirConversionPatternRewriter rewriter, int64_t symbol_kind,
    intptr_t n_operands, MlirValue *operands, MlirType result_type,
    MlirLocation location, MlirValue *result, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  if (n_operands < 0 || n_operands > BATATA_MAX_VALUES || !result)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata runtime call exceeds the closed ABI arity");

  MlirType input_types[BATATA_MAX_VALUES];
  for (intptr_t index = 0; index < n_operands; ++index) {
    if (mlirLogicalResultIsFailure(host->valueType(
            operands[index], &input_types[index], diagnostic,
            diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  char symbol_storage[64];
  MlirStringRef symbol;
  if (mlirLogicalResultIsFailure(target_name(
          symbol_kind, symbol_storage, sizeof(symbol_storage), &symbol,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->ensureFunctionDeclaration(
          anchor, rewriter, symbol, n_operands, input_types, 1, &result_type,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirAttribute callee;
  MlirNamedAttribute named_callee;
  if (mlirLogicalResultIsFailure(host->flatSymbolRefAttribute(
          rewriter, symbol, &callee, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("callee", 6), callee, &named_callee,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char call_storage[16];
  MlirStringRef call_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_FUNC_CALL, call_storage, sizeof(call_storage),
          &call_target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      call_target,
      location,
      n_operands,
      operands,
      1,
      &result_type,
      1,
      &named_callee,
  };

  MlirOperation call;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &descriptor, &call, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          call, 0, result, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return mlirLogicalResultSuccess();
}

static MlirLogicalResult create_integer_constant(
    const MlirBeaverCompilerKernelHostAPI *host,
    MlirConversionPatternRewriter rewriter, MlirLocation location,
    MlirType type, int64_t integer, MlirValue *result,
    MlirStringCallback diagnostic, void *diagnostic_user_data) {
  MlirAttribute value;
  MlirNamedAttribute named_value;
  if (mlirLogicalResultIsFailure(host->integerAttribute(
          type, integer, &value, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("value", 5), value, &named_value,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char target_storage[16];
  MlirStringRef target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_ARITH_CONSTANT, target_storage, sizeof(target_storage),
          &target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      target,
      location,
      0,
      NULL,
      1,
      &type,
      1,
      &named_value,
  };

  MlirOperation constant;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &descriptor, &constant, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          constant, 0, result, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return mlirLogicalResultSuccess();
}

static MlirLogicalResult build_term_list(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation anchor,
    MlirConversionPatternRewriter rewriter, intptr_t n_operands,
    MlirValue *operands, MlirType word_type, MlirLocation location,
    MlirValue *result, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  if (!result || n_operands < 0 || (n_operands > 0 && !operands))
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata list construction shape is invalid");

  MlirValue tail;
  if (mlirLogicalResultIsFailure(create_integer_constant(
          host, rewriter, location, word_type, 1, &tail, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  for (intptr_t index = n_operands; index > 0; --index) {
    MlirValue arguments[2] = {operands[index - 1], tail};
    if (mlirLogicalResultIsFailure(create_runtime_call(
            host, anchor, rewriter, BATATA_RUNTIME_LIST_CONS, 2, arguments,
            word_type, location, &tail, diagnostic, diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  *result = tail;
  return mlirLogicalResultSuccess();
}

static int64_t reversed_name_tail(MlirStringRef name) {
  intptr_t count = name.length < 8 ? name.length : 8;
  uint64_t tail = 0;
  for (intptr_t index = 0; index < count; ++index)
    tail |= ((uint64_t)(uint8_t)name.data[name.length - index - 1])
            << (index * 8);
  return (int64_t)tail;
}

static int64_t fail_invocation(void) {
  if (current_invocation)
    current_invocation->failed = 1;
  return 0;
}

static int64_t value_handle(MlirValue value) {
  return (int64_t)(intptr_t)value.ptr;
}

static int64_t type_handle(MlirType type) {
  return (int64_t)(intptr_t)type.ptr;
}

static int64_t attribute_handle(MlirAttribute attribute) {
  return (int64_t)(intptr_t)attribute.ptr;
}

static int64_t operation_handle(MlirOperation operation) {
  return (int64_t)(intptr_t)operation.ptr;
}

static int64_t location_handle(MlirLocation location) {
  return (int64_t)(intptr_t)location.ptr;
}

static MlirValue value_from_handle(int64_t handle) {
  MlirValue value = {(void *)(intptr_t)handle};
  return value;
}

static MlirType type_from_handle(int64_t handle) {
  MlirType type = {(void *)(intptr_t)handle};
  return type;
}

static MlirAttribute attribute_from_handle(int64_t handle) {
  MlirAttribute attribute = {(void *)(intptr_t)handle};
  return attribute;
}

static MlirOperation operation_from_handle(int64_t handle) {
  MlirOperation operation = {(void *)(intptr_t)handle};
  return operation;
}

static MlirLocation location_from_handle(int64_t handle) {
  MlirLocation location = {(void *)(intptr_t)handle};
  return location;
}

int64_t batata_compiler_abi_healthy(void) {
  return current_invocation && !current_invocation->failed;
}

int64_t batata_compiler_abi_converted_operand_count(void) {
  return current_invocation ? current_invocation->n_operands : fail_invocation();
}

static int64_t source_count(int results) {
  intptr_t n_operands;
  intptr_t n_results;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationCounts(
          invocation->operation, &n_operands, &n_results,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return results ? n_results : n_operands;
}

int64_t batata_compiler_abi_source_operand_count(void) {
  return source_count(0);
}

int64_t batata_compiler_abi_source_result_count(void) {
  return source_count(1);
}

int64_t batata_compiler_abi_converted_operand(int64_t index) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation || index < 0 || index >= invocation->n_operands)
    return fail_invocation();
  return value_handle(invocation->operands[index]);
}

int64_t batata_compiler_abi_source_operand(int64_t index) {
  MlirValue value;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationOperand(
          invocation->operation, index, &value, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return value_handle(value);
}

int64_t batata_compiler_abi_source_result(int64_t index) {
  MlirValue value;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationResult(
          invocation->operation, index, &value, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return value_handle(value);
}

int64_t batata_compiler_abi_operation_location(void) {
  MlirLocation location;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationLocation(
          invocation->operation, &location, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return location_handle(location);
}

int64_t batata_compiler_abi_value_type(int64_t value_handle_value) {
  MlirType type;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->valueType(
          value_from_handle(value_handle_value), &type, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return type_handle(type);
}

int64_t batata_compiler_abi_convert_type(int64_t type_handle_value) {
  MlirType converted;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->convertType(
          invocation->type_converter, type_from_handle(type_handle_value),
          &converted, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return type_handle(converted);
}

int64_t batata_compiler_abi_type_is_i64(int64_t type_handle_value) {
  int result;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->typeIsInteger(
          type_from_handle(type_handle_value), 64, &result,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return result;
}

int64_t batata_compiler_abi_dynamic_type_length(int64_t type_handle_value) {
  MlirStringRef name;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->dynamicTypeName(
          type_from_handle(type_handle_value), &name, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return name.length;
}

int64_t batata_compiler_abi_dynamic_type_tail(int64_t type_handle_value) {
  MlirStringRef name;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->dynamicTypeName(
          type_from_handle(type_handle_value), &name, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return reversed_name_tail(name);
}

int64_t batata_compiler_abi_operation_attribute(int64_t name_id) {
  char storage[80];
  MlirStringRef name;
  MlirAttribute attribute;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(target_name(
          name_id, storage, sizeof(storage), &name, invocation->diagnostic,
          invocation->diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(invocation->host->operationAttribute(
          invocation->operation, name, &attribute, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return attribute_handle(attribute);
}

int64_t batata_compiler_abi_attribute_string_length(
    int64_t attribute_handle_value) {
  MlirStringRef value;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->attributeStringValue(
          attribute_from_handle(attribute_handle_value), &value,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return value.length;
}

int64_t batata_compiler_abi_attribute_string_word(
    int64_t attribute_handle_value, int64_t word_index) {
  MlirStringRef value;
  BatataInvocation *invocation = current_invocation;
  if (!invocation || word_index < 0 ||
      mlirLogicalResultIsFailure(invocation->host->attributeStringValue(
          attribute_from_handle(attribute_handle_value), &value,
          invocation->diagnostic, invocation->diagnostic_user_data)) ||
      word_index * 4 >= value.length)
    return fail_invocation();

  intptr_t offset = word_index * 4;
  intptr_t count = value.length - offset;
  if (count > 4)
    count = 4;
  uint32_t word = 0;
  for (intptr_t index = 0; index < count; ++index)
    word |= ((uint32_t)(uint8_t)value.data[offset + index]) << (index * 8);
  return word;
}

int64_t batata_compiler_abi_integer_type(int64_t width) {
  MlirType type;
  BatataInvocation *invocation = current_invocation;
  if (!invocation || width <= 0 || width > UINT32_MAX ||
      mlirLogicalResultIsFailure(invocation->host->integerType(
          invocation->rewriter, (unsigned)width, &type,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return type_handle(type);
}

int64_t batata_compiler_abi_integer_attribute(int64_t type_handle_value,
                                               int64_t value) {
  MlirAttribute attribute;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->integerAttribute(
          type_from_handle(type_handle_value), value, &attribute,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return attribute_handle(attribute);
}

int64_t batata_compiler_abi_builder_reset(int64_t name_id,
                                          int64_t location_handle_value) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(target_name(
          name_id, invocation->builder_name_storage,
          sizeof(invocation->builder_name_storage), &invocation->builder_name,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  invocation->builder_location = location_from_handle(location_handle_value);
  invocation->builder_operand_count = 0;
  invocation->builder_result_count = 0;
  invocation->builder_attribute_count = 0;
  return 1;
}

int64_t batata_compiler_abi_builder_add_operand(int64_t value_handle_value) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation || invocation->builder_operand_count >= BATATA_MAX_VALUES)
    return fail_invocation();
  invocation->builder_operands[invocation->builder_operand_count++] =
      value_from_handle(value_handle_value);
  return 1;
}

int64_t batata_compiler_abi_builder_add_result_type(
    int64_t type_handle_value) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation || invocation->builder_result_count >= BATATA_MAX_VALUES)
    return fail_invocation();
  invocation->builder_results[invocation->builder_result_count++] =
      type_from_handle(type_handle_value);
  return 1;
}

int64_t batata_compiler_abi_builder_add_attribute(
    int64_t name_id, int64_t attribute_handle_value) {
  char storage[80];
  MlirStringRef name;
  MlirNamedAttribute attribute;
  BatataInvocation *invocation = current_invocation;
  if (!invocation || invocation->builder_attribute_count >= BATATA_MAX_VALUES ||
      mlirLogicalResultIsFailure(target_name(
          name_id, storage, sizeof(storage), &name, invocation->diagnostic,
          invocation->diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(invocation->host->namedAttribute(
          invocation->rewriter, name,
          attribute_from_handle(attribute_handle_value), &attribute,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  invocation->builder_attributes[invocation->builder_attribute_count++] =
      attribute;
  return 1;
}

int64_t batata_compiler_abi_builder_create(void) {
  MlirOperation operation;
  BatataInvocation *invocation = current_invocation;
  if (!invocation)
    return fail_invocation();
  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      invocation->builder_name,
      invocation->builder_location,
      invocation->builder_operand_count,
      invocation->builder_operands,
      invocation->builder_result_count,
      invocation->builder_results,
      invocation->builder_attribute_count,
      invocation->builder_attributes,
  };
  if (mlirLogicalResultIsFailure(invocation->host->createOperation(
          invocation->rewriter, &descriptor, &operation,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return operation_handle(operation);
}

int64_t batata_compiler_abi_builder_create_call(int64_t symbol_id,
                                                int64_t result_type_handle) {
  char symbol_storage[80];
  MlirStringRef symbol;
  MlirType input_types[BATATA_MAX_VALUES];
  MlirType result_type = type_from_handle(result_type_handle);
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(target_name(
          symbol_id, symbol_storage, sizeof(symbol_storage), &symbol,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();

  for (intptr_t index = 0; index < invocation->builder_operand_count; ++index) {
    if (mlirLogicalResultIsFailure(invocation->host->valueType(
            invocation->builder_operands[index], &input_types[index],
            invocation->diagnostic, invocation->diagnostic_user_data)))
      return fail_invocation();
  }

  if (mlirLogicalResultIsFailure(invocation->host->ensureFunctionDeclaration(
          invocation->operation, invocation->rewriter, symbol,
          invocation->builder_operand_count, input_types, 1, &result_type,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();

  MlirAttribute callee;
  MlirNamedAttribute named_callee;
  if (mlirLogicalResultIsFailure(invocation->host->flatSymbolRefAttribute(
          invocation->rewriter, symbol, &callee, invocation->diagnostic,
          invocation->diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(invocation->host->namedAttribute(
          invocation->rewriter, mlirStringRefCreate("callee", 6), callee,
          &named_callee, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();

  char call_storage[80];
  MlirStringRef call_name;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_FUNC_CALL, call_storage, sizeof(call_storage),
          &call_name, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();

  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation), call_name,
      invocation->builder_location, invocation->builder_operand_count,
      invocation->builder_operands, 1, &result_type, 1, &named_callee};
  MlirOperation operation;
  if (mlirLogicalResultIsFailure(invocation->host->createOperation(
          invocation->rewriter, &descriptor, &operation,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return operation_handle(operation);
}

int64_t batata_compiler_abi_operation_result(int64_t operation_handle_value,
                                              int64_t index) {
  MlirValue result;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationResult(
          operation_from_handle(operation_handle_value), index, &result,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return value_handle(result);
}

int64_t batata_compiler_abi_replace_one(int64_t value_handle_value) {
  MlirValue value = value_from_handle(value_handle_value);
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->replaceOperationWithValues(
          invocation->rewriter, invocation->operation, 1, &value,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return 1;
}

int64_t batata_compiler_abi_replace_none(void) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->replaceOperationWithValues(
          invocation->rewriter, invocation->operation, 0, NULL,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return 1;
}

static MlirLogicalResult source_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  if (!pattern)
    return mlirLogicalResultFailure();

  BatataInvocation invocation;
  memset(&invocation, 0, sizeof(invocation));
  invocation.host = host;
  invocation.operation = operation;
  invocation.n_operands = n_operands;
  invocation.operands = operands;
  invocation.rewriter = rewriter;
  invocation.type_converter = type_converter;
  invocation.diagnostic = diagnostic;
  invocation.diagnostic_user_data = diagnostic_user_data;
  BatataInvocation *previous = current_invocation;
  current_invocation = &invocation;
  int64_t accepted = batata_kernel_rewrite(pattern->pattern_id);
  current_invocation = previous;

  if (accepted == 1 && !invocation.failed)
    return mlirLogicalResultSuccess();
  return BATATA_FAIL(diagnostic, diagnostic_user_data,
                     "Batata-authored rewrite rejected the operation");
}

static MlirLogicalResult source_word(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    MlirValue converted, MlirConversionPatternRewriter rewriter,
    MlirLocation location, MlirValue *word, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  MlirValue original;
  MlirType original_type;
  MlirType converted_type;
  int original_is_i64;
  int converted_is_i64;

  if (!word ||
      mlirLogicalResultIsFailure(host->operationOperand(
          operation, 0, &original, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->valueType(
          original, &original_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->valueType(
          converted, &converted_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeIsInteger(
          original_type, 64, &original_is_i64, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeIsInteger(
          converted_type, 64, &converted_is_i64, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (!converted_is_i64)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata term conversion requires an i64 word");

  if (!original_is_i64) {
    MlirStringRef name;
    if (mlirLogicalResultIsFailure(host->dynamicTypeName(
            original_type, &name, diagnostic, diagnostic_user_data)) ||
        name.length <= 0 || name.length > 4096 ||
        batata_kernel_term_type_accept(name.length,
                                       reversed_name_tail(name)) != 1)
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata source type is not a closed term type");

    *word = converted;
    return mlirLogicalResultSuccess();
  }

  MlirValue shift;
  if (mlirLogicalResultIsFailure(create_integer_constant(
          host, rewriter, location, converted_type, 3, &shift, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char target_storage[16];
  MlirStringRef target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_ARITH_SHLI, target_storage, sizeof(target_storage),
          &target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue operands[2] = {converted, shift};
  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      target,
      location,
      2,
      operands,
      1,
      &converted_type,
      0,
      NULL,
  };

  MlirOperation shifted;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &descriptor, &shifted, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          shifted, 0, word, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return mlirLogicalResultSuccess();
}

static MlirLogicalResult box_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)type_converter;
  (void)user_data;
  MlirLocation location;
  MlirValue word;

  if (mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, 1, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_word(
          host, operation, operands[0], rewriter, location, &word, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, &word,
                                          diagnostic, diagnostic_user_data);
}

static MlirLogicalResult predicate_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  MlirType result_type;
  MlirLocation location;
  MlirValue word;
  MlirValue result;
  int result_is_i64;

  if (!pattern ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, 1, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeIsInteger(
          result_type, 64, &result_is_i64, diagnostic, diagnostic_user_data)) ||
      !result_is_i64 ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_word(
          host, operation, operands[0], rewriter, location, &word, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, pattern->target_kind, 1, &word,
          result_type, location, &result, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, &result,
                                          diagnostic, diagnostic_user_data);
}

static MlirLogicalResult binary_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  MlirType result_type;
  MlirLocation location;
  char target_storage[16];
  MlirStringRef target;

  if (!pattern ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, 2, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          pattern->target_kind, target_storage, sizeof(target_storage), &target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, n_operands, operands, rewriter,
                            target, location, 1, &result_type, 0, NULL,
                            diagnostic, diagnostic_user_data);
}

static MlirLogicalResult identity_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)type_converter;
  (void)user_data;

  if (mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, 1, 1, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, operands,
                                          diagnostic, diagnostic_user_data);
}

static MlirLogicalResult literal_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  MlirAttribute value;
  MlirNamedAttribute named_value;
  MlirType result_type;
  MlirLocation location;
  char target_storage[16];
  MlirStringRef target;

  if (!pattern ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, 0, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationAttribute(
          operation, mlirStringRefCreate("value", 5), &value, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("value", 5), value, &named_value,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          pattern->target_kind, target_storage, sizeof(target_storage), &target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, 0, NULL, rewriter, target,
                            location, 1, &result_type, 1, &named_value,
                            diagnostic, diagnostic_user_data);
}

static MlirLogicalResult cmp_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)user_data;
  MlirAttribute predicate;
  MlirStringRef predicate_value;
  MlirType result_type;
  MlirType i1_type;
  MlirAttribute predicate_code_attribute;
  MlirNamedAttribute named_predicate;
  MlirLocation location;

  if (mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, 2, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationAttribute(
          operation, mlirStringRefCreate("predicate", 9), &predicate,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->attributeStringValue(
          predicate, &predicate_value, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (predicate_value.length <= 0 || predicate_value.length > 4)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata comparison predicate is invalid");

  uint32_t predicate_word = 0;
  for (intptr_t index = 0; index < predicate_value.length; ++index)
    predicate_word |= ((uint32_t)(uint8_t)predicate_value.data[index])
                      << (index * 8);

  int64_t predicate_code = batata_kernel_cmp_predicate(
      predicate_value.length, (int64_t)predicate_word);
  if (predicate_code < 0)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata comparison predicate is unsupported");

  if (mlirLogicalResultIsFailure(host->integerType(
          rewriter, 1, &i1_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->integerAttribute(
          result_type, predicate_code, &predicate_code_attribute, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("predicate", 9),
          predicate_code_attribute, &named_predicate, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char cmp_storage[16];
  MlirStringRef cmp_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_ARITH_CMPI, cmp_storage, sizeof(cmp_storage),
          &cmp_target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation cmp_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      cmp_target,
      location,
      n_operands,
      operands,
      1,
      &i1_type,
      1,
      &named_predicate,
  };

  MlirOperation cmp_operation;
  MlirValue cmp_result;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &cmp_descriptor, &cmp_operation, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          cmp_operation, 0, &cmp_result, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char extend_storage[16];
  MlirStringRef extend_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_ARITH_EXTUI, extend_storage, sizeof(extend_storage),
          &extend_target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, 1, &cmp_result, rewriter,
                            extend_target, location, 1, &result_type, 0, NULL,
                            diagnostic, diagnostic_user_data);
}

static MlirLogicalResult yield_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  (void)type_converter;
  MlirLocation location;
  char target_storage[16];
  MlirStringRef target;

  if (!pattern ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, n_operands, 0, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          pattern->target_kind, target_storage, sizeof(target_storage), &target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, n_operands, operands, rewriter,
                            target, location, 0, NULL, 0, NULL, diagnostic,
                            diagnostic_user_data);
}

static MlirLogicalResult runtime_call_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  if (!pattern)
    return mlirLogicalResultFailure();

  int64_t expected_arity = batata_kernel_runtime_arity(pattern->target_kind);
  MlirType result_type;
  MlirLocation location;
  MlirValue result;

  if (expected_arity < 0 ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, expected_arity, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, pattern->target_kind, n_operands, operands,
          result_type, location, &result, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, &result,
                                          diagnostic, diagnostic_user_data);
}

static MlirLogicalResult binary_term_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)user_data;
  MlirType result_type;
  MlirType word_type;
  MlirLocation location;

  if (mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, n_operands, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->integerType(
          rewriter, 64, &word_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue tail;
  if (mlirLogicalResultIsFailure(build_term_list(
          host, operation, rewriter, n_operands, operands, word_type, location,
          &tail, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue binary;
  if (mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, BATATA_RUNTIME_BINARY_FROM_LIST, 1, &tail,
          result_type, location, &binary, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, &binary,
                                          diagnostic, diagnostic_user_data);
}

static MlirLogicalResult aggregate_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  MlirType result_type;
  MlirLocation location;
  int result_is_i64;

  if (!pattern ||
      batata_kernel_aggregate_accept(pattern->target_kind, n_operands) != 1 ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, n_operands, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeIsInteger(
          result_type, 64, &result_is_i64, diagnostic, diagnostic_user_data)) ||
      !result_is_i64 ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)))
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata aggregate source shape is unsupported");

  for (intptr_t index = 0; index < n_operands; ++index) {
    MlirType operand_type;
    int operand_is_i64;
    if (mlirLogicalResultIsFailure(host->valueType(
            operands[index], &operand_type, diagnostic,
            diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->typeIsInteger(
            operand_type, 64, &operand_is_i64, diagnostic,
            diagnostic_user_data)) ||
        !operand_is_i64)
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata aggregate operand is not an i64 word");
  }

  MlirValue list;
  if (mlirLogicalResultIsFailure(build_term_list(
          host, operation, rewriter, n_operands, operands, result_type,
          location, &list, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue result = list;
  if (pattern->target_kind != BATATA_AGGREGATE_LIST &&
      mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, pattern->target_kind, 1, &list,
          result_type, location, &result, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, &result,
                                          diagnostic, diagnostic_user_data);
}

static MlirLogicalResult integer_operation_attribute(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    const char *name, intptr_t name_length, int64_t *value,
    MlirStringCallback diagnostic, void *diagnostic_user_data) {
  MlirAttribute attribute;
  if (!name || name_length <= 0 || !value ||
      mlirLogicalResultIsFailure(host->operationAttribute(
          operation, mlirStringRefCreate(name, name_length), &attribute,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->attributeIntegerValue(
          attribute, value, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return mlirLogicalResultSuccess();
}

static MlirLogicalResult values_are_i64(
    const MlirBeaverCompilerKernelHostAPI *host, intptr_t count,
    MlirValue *values, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  if (count < 0 || (count > 0 && !values))
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata value list shape is invalid");

  for (intptr_t index = 0; index < count; ++index) {
    MlirType type;
    int is_i64;
    if (mlirLogicalResultIsFailure(host->valueType(
            values[index], &type, diagnostic, diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->typeIsInteger(
            type, 64, &is_i64, diagnostic, diagnostic_user_data)) ||
        !is_i64)
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata function value operand is not i64");
  }

  return mlirLogicalResultSuccess();
}

static MlirLogicalResult function_value_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  int64_t fn_idx;
  int64_t env_len;
  int64_t arity = -1;
  int64_t result_mode = -1;
  MlirType result_type;
  MlirLocation location;
  int result_is_i64;

  if (!pattern ||
      mlirLogicalResultIsFailure(integer_operation_attribute(
          host, operation, "fn_idx", 6, &fn_idx, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(integer_operation_attribute(
          host, operation, "env_len", 7, &env_len, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (pattern->target_kind >= BATATA_RUNTIME_MAKE_FUN_WITH_ARITY &&
      mlirLogicalResultIsFailure(integer_operation_attribute(
          host, operation, "arity", 5, &arity, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (pattern->target_kind == BATATA_RUNTIME_MAKE_FUN_WITH_SIGNATURE &&
      mlirLogicalResultIsFailure(integer_operation_attribute(
          host, operation, "result_mode", 11, &result_mode, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (batata_kernel_function_value_accept(
          pattern->target_kind, n_operands, arity, result_mode, env_len) != 1 ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, env_len, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(values_are_i64(
          host, n_operands, operands, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeIsInteger(
          result_type, 64, &result_is_i64, diagnostic, diagnostic_user_data)) ||
      !result_is_i64 ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)))
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata function value shape is unsupported");

  int64_t metadata[4] = {fn_idx, arity, result_mode, env_len};
  intptr_t metadata_count = pattern->target_kind == BATATA_RUNTIME_MAKE_FUN
                                ? 2
                                : pattern->target_kind ==
                                          BATATA_RUNTIME_MAKE_FUN_WITH_ARITY
                                      ? 3
                                      : 4;
  if (metadata_count == 2)
    metadata[1] = env_len;
  else if (metadata_count == 3)
    metadata[2] = env_len;

  MlirValue arguments[BATATA_MAX_VALUES];
  intptr_t argument_count = 0;
  for (intptr_t index = 0; index < metadata_count; ++index) {
    if (mlirLogicalResultIsFailure(create_integer_constant(
            host, rewriter, location, result_type, metadata[index],
            &arguments[argument_count], diagnostic, diagnostic_user_data)))
      return mlirLogicalResultFailure();
    ++argument_count;
  }

  MlirValue zero;
  if (mlirLogicalResultIsFailure(create_integer_constant(
          host, rewriter, location, result_type, 0, &zero, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  for (intptr_t index = 0; index < n_operands; ++index)
    arguments[argument_count++] = operands[index];
  for (intptr_t index = env_len; index < 4; ++index)
    arguments[argument_count++] = zero;

  MlirValue closure;
  if (mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, pattern->target_kind, argument_count,
          arguments, result_type, location, &closure, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, &closure,
                                          diagnostic, diagnostic_user_data);
}

static MlirLogicalResult apply_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)user_data;
  int64_t arg_count;
  MlirType result_type;
  MlirLocation location;
  int result_is_i64;

  if (mlirLogicalResultIsFailure(integer_operation_attribute(
          host, operation, "arg_count", 9, &arg_count, diagnostic,
          diagnostic_user_data)) ||
      batata_kernel_function_value_accept(
          BATATA_TARGET_FN_DISPATCH, n_operands, arg_count, -1, -1) != 1 ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, arg_count + 1, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(values_are_i64(
          host, n_operands, operands, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeIsInteger(
          result_type, 64, &result_is_i64, diagnostic, diagnostic_user_data)) ||
      !result_is_i64 ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)))
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata apply shape is unsupported");

  MlirValue dispatch_arguments[9];
  if (mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, BATATA_RUNTIME_FUN_IDX, 1, operands,
          result_type, location, &dispatch_arguments[0], diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  for (int64_t index = 0; index < 4; ++index) {
    MlirValue index_value;
    if (mlirLogicalResultIsFailure(create_integer_constant(
            host, rewriter, location, result_type, index, &index_value,
            diagnostic, diagnostic_user_data)))
      return mlirLogicalResultFailure();

    MlirValue env_arguments[2] = {operands[0], index_value};
    if (mlirLogicalResultIsFailure(create_runtime_call(
            host, operation, rewriter, BATATA_RUNTIME_FUN_ENV, 2,
            env_arguments, result_type, location,
            &dispatch_arguments[index + 1], diagnostic,
            diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  MlirValue zero;
  if (mlirLogicalResultIsFailure(create_integer_constant(
          host, rewriter, location, result_type, 0, &zero, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  intptr_t dispatch_count = 5;
  for (intptr_t index = 1; index < n_operands; ++index)
    dispatch_arguments[dispatch_count++] = operands[index];
  for (intptr_t index = arg_count; index < 4; ++index)
    dispatch_arguments[dispatch_count++] = zero;

  char symbol_storage[16];
  MlirStringRef symbol;
  MlirAttribute callee;
  MlirNamedAttribute named_callee;
  char target_storage[16];
  MlirStringRef target;
  if (dispatch_count != 9 ||
      mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_FN_DISPATCH, symbol_storage, sizeof(symbol_storage),
          &symbol, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->flatSymbolRefAttribute(
          rewriter, symbol, &callee, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("callee", 6), callee, &named_callee,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_FUNC_CALL, target_storage, sizeof(target_storage),
          &target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, dispatch_count,
                            dispatch_arguments, rewriter, target, location, 1,
                            &result_type, 1, &named_callee, diagnostic,
                            diagnostic_user_data);
}

static MlirLogicalResult func_addr_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)operands;
  (void)user_data;
  MlirAttribute symbol_name;
  MlirStringRef symbol;
  MlirAttribute value;
  MlirNamedAttribute named_value;
  MlirType result_type;
  MlirLocation location;
  char target_storage[16];
  MlirStringRef target;

  if (mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, 0, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationAttribute(
          operation, mlirStringRefCreate("sym_name", 8), &symbol_name,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->attributeStringValue(
          symbol_name, &symbol, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->flatSymbolRefAttribute(
          rewriter, symbol, &value, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("value", 5), value, &named_value,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_FUNC_CONSTANT, target_storage, sizeof(target_storage),
          &target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, 0, NULL, rewriter, target,
                            location, 1, &result_type, 1, &named_value,
                            diagnostic, diagnostic_user_data);
}

static MlirLogicalResult call_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  MlirAttribute arity_attribute;
  int64_t arity;
  MlirAttribute callee_attribute;
  MlirStringRef callee_name;
  MlirAttribute callee;
  MlirNamedAttribute named_callee;
  MlirType result_type;
  MlirLocation location;
  char target_storage[16];
  MlirStringRef target;

  if (!pattern || n_operands < 0 || n_operands > BATATA_MAX_VALUES ||
      n_operands > batata_kernel_structural_limit(BATATA_LIMIT_VALUES) ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, n_operands, 1, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationAttribute(
          operation, mlirStringRefCreate("arity", 5), &arity_attribute,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->attributeIntegerValue(
          arity_attribute, &arity, diagnostic, diagnostic_user_data)) ||
      arity != n_operands ||
      mlirLogicalResultIsFailure(host->operationAttribute(
          operation, mlirStringRefCreate("callee", 6), &callee_attribute,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->attributeStringValue(
          callee_attribute, &callee_name, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->flatSymbolRefAttribute(
          rewriter, callee_name, &callee, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("callee", 6), callee, &named_callee,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          pattern->target_kind, target_storage, sizeof(target_storage), &target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, n_operands, operands, rewriter,
                            target, location, 1, &result_type, 1,
                            &named_callee, diagnostic, diagnostic_user_data);
}

static MlirLogicalResult return_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  (void)type_converter;
  MlirLocation location;
  char target_storage[16];
  MlirStringRef target;

  if (!pattern || n_operands < 0 || n_operands > 1 ||
      mlirLogicalResultIsFailure(validate_shape(
          host, operation, n_operands, n_operands, 0, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          pattern->target_kind, target_storage, sizeof(target_storage), &target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return create_and_replace(host, operation, n_operands, operands, rewriter,
                            target, location, 0, NULL, 0, NULL, diagnostic,
                            diagnostic_user_data);
}

static MlirLogicalResult if_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)user_data;
  intptr_t source_operands;
  intptr_t source_results;
  MlirType result_types[BATATA_MAX_VALUES];
  intptr_t n_result_types;
  MlirType i1_type;
  MlirLocation location;

  if (batata_kernel_structural_limit(BATATA_LIMIT_VALUES) !=
          BATATA_MAX_VALUES ||
      batata_kernel_structural_limit(BATATA_LIMIT_REGIONS) != 2 ||
      mlirLogicalResultIsFailure(host->operationCounts(
          operation, &source_operands, &source_results, diagnostic,
          diagnostic_user_data)) ||
      source_operands != 1 || source_operands != n_operands ||
      source_results < 0 || source_results > BATATA_MAX_VALUES ||
      mlirLogicalResultIsFailure(source_result_types(
          host, operation, type_converter, result_types, BATATA_MAX_VALUES,
          &n_result_types, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->integerType(
          rewriter, 1, &i1_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char truncate_storage[16];
  MlirStringRef truncate_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_ARITH_TRUNCI, truncate_storage,
          sizeof(truncate_storage), &truncate_target, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation truncate_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      truncate_target,
      location,
      1,
      operands,
      1,
      &i1_type,
      0,
      NULL,
  };

  MlirOperation truncate;
  MlirValue condition;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &truncate_descriptor, &truncate, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          truncate, 0, &condition, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char if_storage[16];
  MlirStringRef if_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_SCF_IF, if_storage, sizeof(if_storage), &if_target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation if_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      if_target,
      location,
      1,
      &condition,
      n_result_types,
      result_types,
      0,
      NULL,
  };

  MlirOperation replacement;
  if (mlirLogicalResultIsFailure(host->createOperationWithRegions(
          rewriter, &if_descriptor, 2, &replacement, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithRegions(
      rewriter, replacement, operation, 2, diagnostic, diagnostic_user_data);
}

static MlirLogicalResult try_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)operands;
  (void)user_data;
  intptr_t source_operands;
  intptr_t source_results;
  intptr_t source_regions;
  MlirBlock body_block;
  MlirBlock catch_block;
  intptr_t body_arguments;
  intptr_t catch_arguments;
  MlirOperation body_terminator;
  MlirOperation catch_terminator;
  MlirType result_type;
  MlirType i1_type;
  MlirType i8_type;
  MlirType i64_type;
  MlirType pointer_type;
  int result_is_i64;
  MlirLocation location;

  if (mlirLogicalResultIsFailure(host->operationCounts(
          operation, &source_operands, &source_results, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationRegionCount(
          operation, &source_regions, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->singleRegionBlock(
          operation, 0, &body_block, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->singleRegionBlock(
          operation, 1, &catch_block, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->blockArgumentCount(
          body_block, &body_arguments, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->blockArgumentCount(
          catch_block, &catch_arguments, diagnostic, diagnostic_user_data)) ||
      batata_kernel_try_accept(source_operands, source_results, source_regions,
                               body_arguments, catch_arguments) != 1 ||
      source_operands != n_operands ||
      mlirLogicalResultIsFailure(host->blockTerminator(
          body_block, &body_terminator, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->blockTerminator(
          catch_block, &catch_terminator, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(source_result_type(
          host, operation, type_converter, &result_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeIsInteger(
          result_type, 64, &result_is_i64, diagnostic,
          diagnostic_user_data)) ||
      !result_is_i64 ||
      mlirLogicalResultIsFailure(host->integerType(
          rewriter, 1, &i1_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->integerType(
          rewriter, 8, &i8_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->integerType(
          rewriter, 64, &i64_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->llvmPointerType(
          rewriter, 0, &pointer_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)))
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata ex.try source shape is unsupported");

  MlirValue size;
  if (mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, BATATA_RUNTIME_JMP_BUF_SIZE, 0, NULL,
          i64_type, location, &size, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirAttribute elem_type_attribute;
  MlirAttribute alignment_attribute;
  MlirNamedAttribute alloca_attributes[2];
  if (mlirLogicalResultIsFailure(host->typeAttribute(
          i8_type, &elem_type_attribute, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("elem_type", 9), elem_type_attribute,
          &alloca_attributes[0], diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->integerAttribute(
          i64_type, 8, &alignment_attribute, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("alignment", 9), alignment_attribute,
          &alloca_attributes[1], diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char alloca_storage[16];
  MlirStringRef alloca_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_LLVM_ALLOCA, alloca_storage, sizeof(alloca_storage),
          &alloca_target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation alloca_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation), alloca_target, location, 1,
      &size, 1, &pointer_type, 2, alloca_attributes};
  MlirOperation alloca;
  MlirValue buffer;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &alloca_descriptor, &alloca, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          alloca, 0, &buffer, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue push;
  if (mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, BATATA_RUNTIME_TRY_PUSH, 1, &buffer,
          i64_type, location, &push, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue setjmp_address;
  if (mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, BATATA_RUNTIME_SETJMP_ADDR, 0, NULL,
          i64_type, location, &setjmp_address, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char inttoptr_storage[16];
  MlirStringRef inttoptr_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_LLVM_INTTOPTR, inttoptr_storage,
          sizeof(inttoptr_storage), &inttoptr_target, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation inttoptr_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation), inttoptr_target, location, 1,
      &setjmp_address, 1, &pointer_type, 0, NULL};
  MlirOperation inttoptr;
  MlirValue function_pointer;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &inttoptr_descriptor, &inttoptr, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          inttoptr, 0, &function_pointer, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  const int32_t operand_segments[2] = {2, 0};
  MlirAttribute operand_segments_attribute;
  MlirAttribute bundle_sizes_attribute;
  MlirNamedAttribute call_attributes[2];
  if (mlirLogicalResultIsFailure(host->denseI32ArrayAttribute(
          rewriter, 2, operand_segments, &operand_segments_attribute,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("operandSegmentSizes", 19),
          operand_segments_attribute, &call_attributes[0], diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->denseI32ArrayAttribute(
          rewriter, 0, NULL, &bundle_sizes_attribute, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("op_bundle_sizes", 15),
          bundle_sizes_attribute, &call_attributes[1], diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char llvm_call_storage[16];
  MlirStringRef llvm_call_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_LLVM_CALL, llvm_call_storage,
          sizeof(llvm_call_storage), &llvm_call_target, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue setjmp_operands[2] = {function_pointer, buffer};
  MlirBeaverCompilerKernelOperation llvm_call_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation), llvm_call_target, location, 2,
      setjmp_operands, 1, &i64_type, 2, call_attributes};
  MlirOperation setjmp;
  MlirValue saved;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &llvm_call_descriptor, &setjmp, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          setjmp, 0, &saved, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue zero;
  if (mlirLogicalResultIsFailure(create_integer_constant(
          host, rewriter, location, i64_type, 0, &zero, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirAttribute predicate_attribute;
  MlirNamedAttribute named_predicate;
  if (mlirLogicalResultIsFailure(host->integerAttribute(
          i64_type, 0, &predicate_attribute, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("predicate", 9), predicate_attribute,
          &named_predicate, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char cmp_storage[16];
  MlirStringRef cmp_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_ARITH_CMPI, cmp_storage, sizeof(cmp_storage),
          &cmp_target, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirValue cmp_operands[2] = {saved, zero};
  MlirBeaverCompilerKernelOperation cmp_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation), cmp_target, location, 2,
      cmp_operands, 1, &i1_type, 1, &named_predicate};
  MlirOperation cmp;
  MlirValue condition;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &cmp_descriptor, &cmp, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          cmp, 0, &condition, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char if_storage[16];
  MlirStringRef if_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_SCF_IF, if_storage, sizeof(if_storage), &if_target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation if_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation), if_target, location, 1,
      &condition, 1, &i64_type, 0, NULL};
  MlirOperation replacement;
  if (mlirLogicalResultIsFailure(host->createOperationWithRegions(
          rewriter, &if_descriptor, 2, &replacement, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  char try_pop_storage[32];
  MlirStringRef try_pop_symbol;
  MlirAttribute try_pop_callee;
  MlirNamedAttribute named_try_pop_callee;
  char func_call_storage[16];
  MlirStringRef func_call_target;
  if (mlirLogicalResultIsFailure(target_name(
          BATATA_RUNTIME_TRY_POP, try_pop_storage, sizeof(try_pop_storage),
          &try_pop_symbol, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->ensureFunctionDeclaration(
          operation, rewriter, try_pop_symbol, 0, NULL, 1, &i64_type,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->flatSymbolRefAttribute(
          rewriter, try_pop_symbol, &try_pop_callee, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("callee", 6), try_pop_callee,
          &named_try_pop_callee, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          BATATA_TARGET_FUNC_CALL, func_call_storage,
          sizeof(func_call_storage), &func_call_target, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelOperation try_pop_descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation), func_call_target, location, 0,
      NULL, 1, &i64_type, 1, &named_try_pop_callee};
  MlirOperation catch_pop;
  MlirOperation body_pop;
  if (mlirLogicalResultIsFailure(host->createOperationAtBlockStart(
          rewriter, catch_block, &try_pop_descriptor, &catch_pop, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->createOperationBefore(
          rewriter, body_terminator, &try_pop_descriptor, &body_pop,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  (void)push;
  (void)catch_terminator;
  return host->replaceOperationWithRegions(
      rewriter, replacement, operation, 2, diagnostic, diagnostic_user_data);
}

static MlirLogicalResult unsupported_var_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)host;
  (void)operation;
  (void)n_operands;
  (void)operands;
  (void)rewriter;
  (void)type_converter;
  (void)user_data;
  return BATATA_FAIL(diagnostic, diagnostic_user_data,
                     "source variable materialization is incomplete");
}

static MlirLogicalResult func_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  const BatataPattern *pattern = (const BatataPattern *)user_data;
  (void)operands;
  intptr_t source_operands;
  intptr_t source_results;
  MlirBlock block;
  intptr_t n_arguments;
  MlirType argument_types[BATATA_MAX_VALUES];
  MlirOperation terminator;
  intptr_t n_return_values;
  intptr_t terminator_results;
  MlirType return_types[BATATA_MAX_VALUES];

  if (!pattern || n_operands != 0 ||
      batata_kernel_structural_limit(BATATA_LIMIT_VALUES) !=
          BATATA_MAX_VALUES ||
      mlirLogicalResultIsFailure(host->operationCounts(
          operation, &source_operands, &source_results, diagnostic,
          diagnostic_user_data)) ||
      source_operands != 0 || source_results != 0 ||
      mlirLogicalResultIsFailure(host->singleRegionBlock(
          operation, 0, &block, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->blockArgumentCount(
          block, &n_arguments, diagnostic, diagnostic_user_data)) ||
      n_arguments < 0 || n_arguments > BATATA_MAX_VALUES)
    return mlirLogicalResultFailure();

  for (intptr_t index = 0; index < n_arguments; ++index) {
    MlirValue argument;
    MlirType source_type;
    if (mlirLogicalResultIsFailure(host->blockArgument(
            block, index, &argument, diagnostic, diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->valueType(
            argument, &source_type, diagnostic, diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->convertType(
            type_converter, source_type, &argument_types[index], diagnostic,
            diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  if (mlirLogicalResultIsFailure(host->blockTerminator(
          block, &terminator, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationCounts(
          terminator, &n_return_values, &terminator_results, diagnostic,
          diagnostic_user_data)) ||
      terminator_results != 0 || n_return_values < 0 ||
      n_return_values > BATATA_MAX_VALUES)
    return mlirLogicalResultFailure();

  for (intptr_t index = 0; index < n_return_values; ++index) {
    MlirValue value;
    MlirType source_type;
    if (mlirLogicalResultIsFailure(host->operationOperand(
            terminator, index, &value, diagnostic, diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->valueType(
            value, &source_type, diagnostic, diagnostic_user_data)) ||
        mlirLogicalResultIsFailure(host->convertType(
            type_converter, source_type, &return_types[index], diagnostic,
            diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  MlirType function_type;
  MlirAttribute function_type_attribute;
  MlirNamedAttribute named_function_type;
  MlirAttribute sym_name_attribute;
  MlirStringRef sym_name;
  MlirNamedAttribute named_sym_name;
  MlirLocation location;
  char target_storage[16];
  MlirStringRef target;

  if (mlirLogicalResultIsFailure(host->functionType(
          rewriter, n_arguments, argument_types, n_return_values, return_types,
          &function_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->typeAttribute(
          function_type, &function_type_attribute, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("function_type", 13),
          function_type_attribute, &named_function_type, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationAttribute(
          operation, mlirStringRefCreate("sym_name", 8), &sym_name_attribute,
          diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->attributeStringValue(
          sym_name_attribute, &sym_name, diagnostic, diagnostic_user_data)) ||
      sym_name.length <= 0 ||
      mlirLogicalResultIsFailure(host->namedAttribute(
          rewriter, mlirStringRefCreate("sym_name", 8), sym_name_attribute,
          &named_sym_name, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(target_name(
          pattern->target_kind, target_storage, sizeof(target_storage), &target,
          diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  MlirNamedAttribute attributes[2] = {named_sym_name, named_function_type};
  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      target,
      location,
      0,
      NULL,
      0,
      NULL,
      2,
      attributes,
  };

  MlirOperation replacement;
  if (mlirLogicalResultIsFailure(host->createOperationWithRegions(
          rewriter, &descriptor, 1, &replacement, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithRegions(
      rewriter, replacement, operation, 1, diagnostic, diagnostic_user_data);
}

enum BatataRewriteAction {
  BATATA_ACTION_AGGREGATE = 1,
  BATATA_ACTION_APPLY = 2,
  BATATA_ACTION_BINARY = 3,
  BATATA_ACTION_BINARY_TERM = 4,
  BATATA_ACTION_BOX = 5,
  BATATA_ACTION_CALL = 6,
  BATATA_ACTION_CMP = 7,
  BATATA_ACTION_FUNC_ADDR = 8,
  BATATA_ACTION_FUNC = 9,
  BATATA_ACTION_FUNCTION_VALUE = 10,
  BATATA_ACTION_IDENTITY = 11,
  BATATA_ACTION_IF = 12,
  BATATA_ACTION_LITERAL = 13,
  BATATA_ACTION_PREDICATE = 14,
  BATATA_ACTION_RETURN = 15,
  BATATA_ACTION_RUNTIME_CALL = 16,
  BATATA_ACTION_TRY = 17,
  BATATA_ACTION_UNSUPPORTED = 18,
  BATATA_ACTION_YIELD = 19,
};

static MlirBeaverCompilerKernelRewriteFn rewrite_for_action(int64_t action) {
  switch (action) {
  case BATATA_ACTION_AGGREGATE:
    return source_rewrite;
  case BATATA_ACTION_APPLY:
    return apply_rewrite;
  case BATATA_ACTION_BINARY:
    return source_rewrite;
  case BATATA_ACTION_BINARY_TERM:
    return source_rewrite;
  case BATATA_ACTION_BOX:
    return source_rewrite;
  case BATATA_ACTION_CALL:
    return call_rewrite;
  case BATATA_ACTION_CMP:
    return source_rewrite;
  case BATATA_ACTION_FUNC_ADDR:
    return func_addr_rewrite;
  case BATATA_ACTION_FUNC:
    return func_rewrite;
  case BATATA_ACTION_FUNCTION_VALUE:
    return function_value_rewrite;
  case BATATA_ACTION_IDENTITY:
    return source_rewrite;
  case BATATA_ACTION_IF:
    return if_rewrite;
  case BATATA_ACTION_LITERAL:
    return source_rewrite;
  case BATATA_ACTION_PREDICATE:
    return source_rewrite;
  case BATATA_ACTION_RETURN:
    return return_rewrite;
  case BATATA_ACTION_RUNTIME_CALL:
    return source_rewrite;
  case BATATA_ACTION_TRY:
    return try_rewrite;
  case BATATA_ACTION_UNSUPPORTED:
    return unsupported_var_rewrite;
  case BATATA_ACTION_YIELD:
    return source_rewrite;
  default:
    return NULL;
  }
}

static MlirLogicalResult decode_namespace(char *storage, intptr_t capacity,
                                          intptr_t *length) {
  int64_t source_length = batata_kernel_pattern_namespace_length();
  if (!storage || !length || source_length <= 0 || source_length > capacity)
    return mlirLogicalResultFailure();

  for (int64_t offset = 0; offset < source_length; offset += 4) {
    int64_t word = batata_kernel_pattern_namespace_word(offset / 4);
    if (word < 0 || word > UINT32_MAX)
      return mlirLogicalResultFailure();
    int64_t remaining = source_length - offset;
    decode_word((uint32_t)word, storage + offset, remaining < 4 ? remaining : 4);
  }

  *length = source_length;
  return mlirLogicalResultSuccess();
}

static MlirLogicalResult decode_pattern_root(int64_t pattern, char *storage,
                                             intptr_t capacity,
                                             intptr_t *length) {
  int64_t source_length = batata_kernel_pattern_root_length(pattern);
  if (!storage || !length || source_length <= 0 || source_length > capacity)
    return mlirLogicalResultFailure();

  for (int64_t offset = 0; offset < source_length; offset += 4) {
    int64_t word = batata_kernel_pattern_root_word(pattern, offset / 4);
    if (word < 0 || word > UINT32_MAX)
      return mlirLogicalResultFailure();
    int64_t remaining = source_length - offset;
    decode_word((uint32_t)word, storage + offset, remaining < 4 ? remaining : 4);
  }

  *length = source_length;
  return mlirLogicalResultSuccess();
}

static void destroy_pattern(void *user_data) { free(user_data); }

BATATA_KERNEL_EXPORT uint32_t batata_conversion_abi_version(void) {
  return MLIR_BEAVER_COMPILER_KERNEL_ABI_VERSION;
}

BATATA_KERNEL_EXPORT MlirStringRef batata_conversion_manifest(void) {
  static const char identity[] = BATATA_KERNEL_IDENTITY;
  return mlirStringRefCreate(identity, sizeof(identity) - 1);
}

BATATA_KERNEL_EXPORT MlirLogicalResult batata_populate_ex_patterns(
    MlirRewritePatternSet pattern_set, MlirTypeConverter type_converter,
    const MlirBeaverCompilerKernelHostAPI *host, void *host_context,
    MlirStringCallback diagnostic, void *diagnostic_user_data) {
  if (!host || host->abiVersion != MLIR_BEAVER_COMPILER_KERNEL_ABI_VERSION ||
      host->structSize < sizeof(MlirBeaverCompilerKernelHostAPI) ||
      !host->addPattern || !host->operationResult ||
      !host->operationLocation || !host->valueType || !host->convertType ||
      !host->createOperation || !host->replaceOperationWithValues ||
      !host->operationAttribute || !host->attributeStringValue ||
      !host->integerType || !host->integerAttribute || !host->namedAttribute ||
      !host->operationCounts || !host->flatSymbolRefAttribute ||
      !host->ensureFunctionDeclaration || !host->operationOperand ||
      !host->attributeIntegerValue || !host->singleRegionBlock ||
      !host->blockArgumentCount || !host->blockArgument ||
      !host->blockTerminator || !host->functionType || !host->typeAttribute ||
      !host->createOperationWithRegions ||
      !host->replaceOperationWithRegions ||
      !host->typeIsInteger || !host->dynamicTypeName ||
      !host->llvmPointerType || !host->denseI32ArrayAttribute ||
      !host->createOperationAtBlockStart || !host->createOperationBefore ||
      !host->operationRegionCount ||
      batata_kernel_structural_limit(BATATA_LIMIT_VALUES) !=
          BATATA_MAX_VALUES ||
      batata_kernel_structural_limit(BATATA_LIMIT_REGIONS) != 2)
    return mlirLogicalResultFailure();

  int64_t pattern_count = batata_kernel_pattern_count();
  char pattern_namespace[32];
  intptr_t namespace_length;
  if (pattern_count <= 0 || pattern_count > 256 ||
      mlirLogicalResultIsFailure(decode_namespace(
          pattern_namespace, sizeof(pattern_namespace), &namespace_length)))
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata pattern registry metadata is invalid");

  for (int64_t index = 0; index < pattern_count; ++index) {
    BatataPattern *source = (BatataPattern *)calloc(1, sizeof(BatataPattern));
    if (!source)
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata pattern registry allocation failed");

    source->pattern_id = index;
    source->target_kind = batata_kernel_pattern_target(index);
    source->rewrite = rewrite_for_action(batata_kernel_pattern_action(index));
    if (!source->rewrite || source->target_kind < 0 ||
        mlirLogicalResultIsFailure(decode_pattern_root(
            index, source->root, sizeof(source->root), &source->root_length)) ||
        namespace_length + source->root_length >
            (intptr_t)sizeof(source->name)) {
      destroy_pattern(source);
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata pattern descriptor is invalid");
    }

    memcpy(source->name, pattern_namespace, (size_t)namespace_length);
    memcpy(source->name + namespace_length, source->root,
           (size_t)source->root_length);
    source->name_length = namespace_length + source->root_length;

    MlirBeaverCompilerKernelPattern descriptor = {
        sizeof(MlirBeaverCompilerKernelPattern),
        mlirStringRefCreate(source->name, source->name_length),
        mlirStringRefCreate(source->root, source->root_length),
        mlirStringRefCreate("1", 1),
        1,
        source->rewrite,
        destroy_pattern,
        (void *)source,
    };

    if (mlirLogicalResultIsFailure(host->addPattern(
            host_context, pattern_set, type_converter, &descriptor))) {
      destroy_pattern(source);
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata pattern registration failed");
    }
  }

  return mlirLogicalResultSuccess();
}
