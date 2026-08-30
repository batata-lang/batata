#include "mlir-c/Beaver/CompilerKernel.h"

#include <stdint.h>

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

typedef struct {
  const char *name;
  intptr_t name_length;
  const char *root;
  intptr_t root_length;
  int64_t target_kind;
  MlirBeaverCompilerKernelRewriteFn rewrite;
} BatataPattern;

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

static int64_t reversed_name_tail(MlirStringRef name) {
  intptr_t count = name.length < 8 ? name.length : 8;
  uint64_t tail = 0;
  for (intptr_t index = 0; index < count; ++index)
    tail |= ((uint64_t)(uint8_t)name.data[name.length - index - 1])
            << (index * 8);
  return (int64_t)tail;
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
  if (mlirLogicalResultIsFailure(create_integer_constant(
          host, rewriter, location, word_type, 1, &tail, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  for (intptr_t index = n_operands; index > 0; --index) {
    MlirValue arguments[2] = {operands[index - 1], tail};
    if (mlirLogicalResultIsFailure(create_runtime_call(
            host, operation, rewriter, BATATA_RUNTIME_LIST_CONS, 2, arguments,
            word_type, location, &tail, diagnostic, diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  MlirValue binary;
  if (mlirLogicalResultIsFailure(create_runtime_call(
          host, operation, rewriter, BATATA_RUNTIME_BINARY_FROM_LIST, 1, &tail,
          result_type, location, &binary, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(rewriter, operation, 1, &binary,
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

#define BATATA_PATTERN(name_literal, root_literal, kind, callback)             \
  {                                                                            \
    name_literal, sizeof(name_literal) - 1, root_literal,                       \
        sizeof(root_literal) - 1, kind, callback                               \
  }

static const BatataPattern patterns[] = {
    BATATA_PATTERN("batata.ex.add", "ex.add", BATATA_TARGET_ARITH_ADDI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.binary", "ex.binary", 0, binary_term_rewrite),
    BATATA_PATTERN("batata.ex.binary_decode16", "ex.binary_decode16", BATATA_RUNTIME_BINARY_DECODE16,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_encode16", "ex.binary_encode16", BATATA_RUNTIME_BINARY_ENCODE16,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_from_list", "ex.binary_from_list", BATATA_RUNTIME_BINARY_FROM_LIST,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_get", "ex.binary_get", BATATA_RUNTIME_BINARY_GET,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_length", "ex.binary_length", BATATA_RUNTIME_BINARY_LENGTH,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_part", "ex.binary_part",
                   BATATA_RUNTIME_BINARY_PART, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_quote", "ex.binary_quote", BATATA_RUNTIME_BINARY_QUOTE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_slice", "ex.binary_slice", BATATA_RUNTIME_BINARY_SLICE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_utf8_get", "ex.binary_utf8_get", BATATA_RUNTIME_BINARY_UTF8_GET,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_utf8_length", "ex.binary_utf8_length", BATATA_RUNTIME_BINARY_UTF8_LENGTH,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.binary_utf8_width", "ex.binary_utf8_width", BATATA_RUNTIME_BINARY_UTF8_WIDTH,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.box", "ex.box", 0, box_rewrite),
    BATATA_PATTERN("batata.ex.call", "ex.call", BATATA_TARGET_FUNC_CALL,
                   call_rewrite),
    BATATA_PATTERN("batata.ex.catch_value", "ex.catch_value", BATATA_RUNTIME_CATCH_VALUE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.clock_init", "ex.clock_init", BATATA_RUNTIME_CLOCK_INIT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.cmp", "ex.cmp", BATATA_TARGET_ARITH_CMPI,
                   cmp_rewrite),
    BATATA_PATTERN("batata.ex.cont_active", "ex.cont_active", BATATA_RUNTIME_CONT_ACTIVE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.cont_clear", "ex.cont_clear", BATATA_RUNTIME_CONT_CLEAR,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.cont_load_acc", "ex.cont_load_acc", BATATA_RUNTIME_CONT_LOAD_ACC,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.cont_load_arg", "ex.cont_load_arg", BATATA_RUNTIME_CONT_LOAD_ARG,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.cont_load_cursor", "ex.cont_load_cursor", BATATA_RUNTIME_CONT_LOAD_CURSOR,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.cont_pending", "ex.cont_pending", BATATA_RUNTIME_CONT_PENDING,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.cont_save", "ex.cont_save", BATATA_RUNTIME_CONT_SAVE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.current_entry", "ex.current_entry", BATATA_RUNTIME_CURRENT_ENTRY,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.demonitor", "ex.demonitor", BATATA_RUNTIME_DEMONITOR,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.div", "ex.div", BATATA_TARGET_ARITH_DIVSI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_count", "ex.enumerable_count", BATATA_RUNTIME_ENUMERABLE_COUNT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_flat_map_term_fun", "ex.enumerable_flat_map_term_fun", BATATA_RUNTIME_ENUMERABLE_FLAT_MAP_TERM_FUN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_intersperse", "ex.enumerable_intersperse", BATATA_RUNTIME_ENUMERABLE_INTERSPERSE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_into_map", "ex.enumerable_into_map", BATATA_RUNTIME_ENUMERABLE_INTO_MAP,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_map_fun", "ex.enumerable_map_fun", BATATA_RUNTIME_ENUMERABLE_MAP_FUN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_map_term_fun", "ex.enumerable_map_term_fun", BATATA_RUNTIME_ENUMERABLE_MAP_TERM_FUN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_map_term_fun_c", "ex.enumerable_map_term_fun_c", BATATA_RUNTIME_ENUMERABLE_MAP_TERM_FUN_C,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_reduce", "ex.enumerable_reduce", BATATA_RUNTIME_ENUMERABLE_REDUCE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_reduce_c", "ex.enumerable_reduce_c", BATATA_RUNTIME_ENUMERABLE_REDUCE_C,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_reduce_fun", "ex.enumerable_reduce_fun", BATATA_RUNTIME_ENUMERABLE_REDUCE_FUN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_reduce_range", "ex.enumerable_reduce_range", BATATA_RUNTIME_ENUMERABLE_REDUCE_RANGE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_to_list", "ex.enumerable_to_list", BATATA_RUNTIME_ENUMERABLE_TO_LIST,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.enumerable_to_list_range", "ex.enumerable_to_list_range", BATATA_RUNTIME_ENUMERABLE_TO_LIST_RANGE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exit", "ex.exit", BATATA_RUNTIME_EXIT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exported_clone", "ex.exported_clone",
                   BATATA_RUNTIME_EXPORTED_CLONE, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exported_destroy", "ex.exported_destroy",
                   BATATA_RUNTIME_EXPORTED_DESTROY, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exported_get", "ex.exported_get",
                   BATATA_RUNTIME_EXPORTED_GET, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exported_length", "ex.exported_length",
                   BATATA_RUNTIME_EXPORTED_LENGTH, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.file_read", "ex.file_read", BATATA_RUNTIME_FILE_READ,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.file_read_lines", "ex.file_read_lines", BATATA_RUNTIME_FILE_READ_LINES,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.float_lit", "ex.float_lit", BATATA_RUNTIME_FLOAT_LIT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.float_to_binary_short", "ex.float_to_binary_short", BATATA_RUNTIME_FLOAT_TO_BINARY_SHORT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.fun_arity", "ex.fun_arity", BATATA_RUNTIME_FUN_ARITY,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.fun_result_mode", "ex.fun_result_mode", BATATA_RUNTIME_FUN_RESULT_MODE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.func", "ex.func", BATATA_TARGET_FUNC_FUNC,
                   func_rewrite),
    BATATA_PATTERN("batata.ex.if", "ex.if", BATATA_TARGET_SCF_IF, if_rewrite),
    BATATA_PATTERN("batata.ex.int_to_hex", "ex.int_to_hex", BATATA_RUNTIME_INT_TO_HEX,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.int_to_string", "ex.int_to_string", BATATA_RUNTIME_INT_TO_STRING,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.int_to_string_base", "ex.int_to_string_base", BATATA_RUNTIME_INT_TO_STRING_BASE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.iodata_to_binary", "ex.iodata_to_binary", BATATA_RUNTIME_IODATA_TO_BINARY,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.is_atom", "ex.is_atom", BATATA_RUNTIME_IS_ATOM,
                   predicate_rewrite),
    BATATA_PATTERN("batata.ex.is_binary", "ex.is_binary", BATATA_RUNTIME_IS_BINARY,
                   predicate_rewrite),
    BATATA_PATTERN("batata.ex.is_float", "ex.is_float", BATATA_RUNTIME_IS_FLOAT,
                   predicate_rewrite),
    BATATA_PATTERN("batata.ex.is_integer", "ex.is_integer", BATATA_RUNTIME_IS_INTEGER,
                   predicate_rewrite),
    BATATA_PATTERN("batata.ex.is_list", "ex.is_list", BATATA_RUNTIME_IS_LIST,
                   predicate_rewrite),
    BATATA_PATTERN("batata.ex.is_map", "ex.is_map", BATATA_RUNTIME_IS_MAP,
                   predicate_rewrite),
    BATATA_PATTERN("batata.ex.is_tuple", "ex.is_tuple", BATATA_RUNTIME_IS_TUPLE,
                   predicate_rewrite),
    BATATA_PATTERN("batata.ex.link", "ex.link", BATATA_RUNTIME_LINK,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.list_cons", "ex.list_cons",
                   BATATA_RUNTIME_LIST_CONS, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.list_flatten", "ex.list_flatten", BATATA_RUNTIME_LIST_FLATTEN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.list_get", "ex.list_get", BATATA_RUNTIME_LIST_GET,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.list_head", "ex.list_head", BATATA_RUNTIME_LIST_HEAD,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.list_length", "ex.list_length", BATATA_RUNTIME_LIST_LENGTH,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.list_tail", "ex.list_tail", BATATA_RUNTIME_LIST_TAIL,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.lit", "ex.lit", BATATA_TARGET_ARITH_CONSTANT,
                   literal_rewrite),
    BATATA_PATTERN("batata.ex.mailbox_clear", "ex.mailbox_clear", BATATA_RUNTIME_MAILBOX_CLEAR,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.mailbox_len", "ex.mailbox_len", BATATA_RUNTIME_MAILBOX_LEN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.mailbox_peek", "ex.mailbox_peek", BATATA_RUNTIME_MAILBOX_PEEK,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.mailbox_remove", "ex.mailbox_remove", BATATA_RUNTIME_MAILBOX_REMOVE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.map_fetch", "ex.map_fetch", BATATA_RUNTIME_MAP_FETCH,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.map_length", "ex.map_length", BATATA_RUNTIME_MAP_LENGTH,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.map_put", "ex.map_put", BATATA_RUNTIME_MAP_PUT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.mapset_from_list", "ex.mapset_from_list", BATATA_RUNTIME_MAPSET_FROM_LIST,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.mapset_member", "ex.mapset_member", BATATA_RUNTIME_MAPSET_MEMBER,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.mapset_put", "ex.mapset_put", BATATA_RUNTIME_MAPSET_PUT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.monitor", "ex.monitor", BATATA_RUNTIME_MONITOR,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.monotonic_time", "ex.monotonic_time", BATATA_RUNTIME_MONOTONIC_TIME,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.mul", "ex.mul", BATATA_TARGET_ARITH_MULI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.native_time", "ex.native_time", BATATA_RUNTIME_NATIVE_TIME,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.nil_word", "ex.nil_word", BATATA_RUNTIME_NIL,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.process_done", "ex.process_done", BATATA_RUNTIME_PROCESS_DONE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.process_exit", "ex.process_exit", BATATA_RUNTIME_PROCESS_EXIT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.process_exit_reason", "ex.process_exit_reason", BATATA_RUNTIME_PROCESS_EXIT_REASON,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.process_result", "ex.process_result", BATATA_RUNTIME_PROCESS_RESULT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.process_table_reset", "ex.process_table_reset",
                   BATATA_RUNTIME_PROCESS_TABLE_RESET, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.process_trap_exit", "ex.process_trap_exit", BATATA_RUNTIME_PROCESS_TRAP_EXIT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.process_wait", "ex.process_wait", BATATA_RUNTIME_PROCESS_WAIT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.processes_runnable", "ex.processes_runnable", BATATA_RUNTIME_PROCESSES_RUNNABLE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.raise", "ex.raise", BATATA_RUNTIME_RAISE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.receive", "ex.receive", BATATA_RUNTIME_RECEIVE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.receive_cont_save", "ex.receive_cont_save", BATATA_RUNTIME_RECEIVE_CONT_SAVE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.receive_start", "ex.receive_start", BATATA_RUNTIME_RECEIVE_START,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.receive_start_set", "ex.receive_start_set", BATATA_RUNTIME_RECEIVE_START_SET,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.reduction_tick", "ex.reduction_tick", BATATA_RUNTIME_CLOCK_TICK,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.rem", "ex.rem", BATATA_TARGET_ARITH_REMSI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.result_atom_name", "ex.result_atom_name",
                   BATATA_RUNTIME_RESULT_ATOM_NAME, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_create", "ex.result_create",
                   BATATA_RUNTIME_RESULT_CREATE, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_destroy", "ex.result_destroy",
                   BATATA_RUNTIME_RESULT_DESTROY, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_exception_kind",
                   "ex.result_exception_kind",
                   BATATA_RUNTIME_RESULT_EXCEPTION_KIND,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_exception_reason",
                   "ex.result_exception_reason",
                   BATATA_RUNTIME_RESULT_EXCEPTION_REASON,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_root_kind", "ex.result_root_kind",
                   BATATA_RUNTIME_RESULT_ROOT_KIND, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_root_word", "ex.result_root_word",
                   BATATA_RUNTIME_RESULT_ROOT_WORD, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_term_get", "ex.result_term_get",
                   BATATA_RUNTIME_RESULT_TERM_GET, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_term_kind", "ex.result_term_kind",
                   BATATA_RUNTIME_RESULT_TERM_KIND, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.result_term_length", "ex.result_term_length",
                   BATATA_RUNTIME_RESULT_TERM_LENGTH, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.return", "ex.return",
                   BATATA_TARGET_FUNC_RETURN, return_rewrite),
    BATATA_PATTERN("batata.ex.runtime_create", "ex.runtime_create",
                   BATATA_RUNTIME_RUNTIME_CREATE, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.runtime_destroy", "ex.runtime_destroy",
                   BATATA_RUNTIME_RUNTIME_DESTROY, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.runtime_enter", "ex.runtime_enter",
                   BATATA_RUNTIME_RUNTIME_ENTER, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.runtime_leave", "ex.runtime_leave",
                   BATATA_RUNTIME_RUNTIME_LEAVE, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.schedule_next", "ex.schedule_next", BATATA_RUNTIME_SCHEDULE_NEXT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.self", "ex.self", BATATA_RUNTIME_SELF,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.send", "ex.send", BATATA_RUNTIME_SEND,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.spawn", "ex.spawn", BATATA_RUNTIME_SPAWN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.stream_drop", "ex.stream_drop", BATATA_RUNTIME_STREAM_DROP,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.stream_filter", "ex.stream_filter", BATATA_RUNTIME_STREAM_FILTER,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.stream_take", "ex.stream_take", BATATA_RUNTIME_STREAM_TAKE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.string_printable", "ex.string_printable", BATATA_RUNTIME_STRING_PRINTABLE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.string_to_atom", "ex.string_to_atom", BATATA_RUNTIME_STRING_TO_ATOM,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.string_to_existing_atom", "ex.string_to_existing_atom", BATATA_RUNTIME_STRING_TO_EXISTING_ATOM,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.string_to_float", "ex.string_to_float", BATATA_RUNTIME_STRING_TO_FLOAT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.string_to_int", "ex.string_to_int", BATATA_RUNTIME_STRING_TO_INT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.sub", "ex.sub", BATATA_TARGET_ARITH_SUBI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.term_eq", "ex.term_eq", BATATA_RUNTIME_TERM_EQ,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_eq_loose", "ex.term_eq_loose", BATATA_RUNTIME_TERM_EQ_LOOSE,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_export", "ex.term_export",
                   BATATA_RUNTIME_TERM_EXPORT, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_handle_destroy", "ex.term_handle_destroy",
                   BATATA_RUNTIME_HANDLE_DESTROY, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_handle_export", "ex.term_handle_export",
                   BATATA_RUNTIME_HANDLE_EXPORT, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_import", "ex.term_import",
                   BATATA_RUNTIME_TERM_IMPORT, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.throw", "ex.throw", BATATA_RUNTIME_THROW,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.to_int", "ex.to_int", BATATA_RUNTIME_TO_INT,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.to_word", "ex.to_word", 0, identity_rewrite),
    BATATA_PATTERN("batata.ex.tuple_get", "ex.tuple_get", BATATA_RUNTIME_TUPLE_GET,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.tuple_length", "ex.tuple_length", BATATA_RUNTIME_TUPLE_LENGTH,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.unbox", "ex.unbox", 0, identity_rewrite),
    BATATA_PATTERN("batata.ex.unique_integer", "ex.unique_integer", BATATA_RUNTIME_UNIQUE_INTEGER,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.unlink", "ex.unlink", BATATA_RUNTIME_UNLINK,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.worker_run", "ex.worker_run", BATATA_RUNTIME_WORKER_RUN,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.yield", "ex.yield", BATATA_TARGET_SCF_YIELD,
                   yield_rewrite),
    BATATA_PATTERN("batata.ex.yield_mark", "ex.yield_mark", BATATA_RUNTIME_YIELD_MARK,
                   runtime_call_rewrite),
};

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
      batata_kernel_structural_limit(BATATA_LIMIT_VALUES) !=
          BATATA_MAX_VALUES ||
      batata_kernel_structural_limit(BATATA_LIMIT_REGIONS) != 2)
    return mlirLogicalResultFailure();

  for (intptr_t index = 0;
       index < (intptr_t)(sizeof(patterns) / sizeof(patterns[0])); ++index) {
    const BatataPattern *source = &patterns[index];
    MlirBeaverCompilerKernelPattern descriptor = {
        sizeof(MlirBeaverCompilerKernelPattern),
        mlirStringRefCreate(source->name, source->name_length),
        mlirStringRefCreate(source->root, source->root_length),
        mlirStringRefCreate("1", 1),
        1,
        source->rewrite,
        NULL,
        (void *)source,
    };

    if (mlirLogicalResultIsFailure(host->addPattern(
            host_context, pattern_set, type_converter, &descriptor)))
      return BATATA_FAIL(diagnostic, diagnostic_user_data,
                         "Batata pattern registration failed");
  }

  return mlirLogicalResultSuccess();
}
