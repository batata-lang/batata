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
  if (n_operands < 0 || n_operands > 3 || !result)
    return BATATA_FAIL(diagnostic, diagnostic_user_data,
                       "Batata runtime call exceeds the closed ABI arity");

  MlirType input_types[3];
  for (intptr_t index = 0; index < n_operands; ++index) {
    if (mlirLogicalResultIsFailure(host->valueType(
            operands[index], &input_types[index], diagnostic,
            diagnostic_user_data)))
      return mlirLogicalResultFailure();
  }

  char symbol_storage[32];
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
    BATATA_PATTERN("batata.ex.binary_part", "ex.binary_part",
                   BATATA_RUNTIME_BINARY_PART, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.call", "ex.call", BATATA_TARGET_FUNC_CALL,
                   call_rewrite),
    BATATA_PATTERN("batata.ex.cmp", "ex.cmp", BATATA_TARGET_ARITH_CMPI,
                   cmp_rewrite),
    BATATA_PATTERN("batata.ex.div", "ex.div", BATATA_TARGET_ARITH_DIVSI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.exported_clone", "ex.exported_clone",
                   BATATA_RUNTIME_EXPORTED_CLONE, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exported_destroy", "ex.exported_destroy",
                   BATATA_RUNTIME_EXPORTED_DESTROY, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exported_get", "ex.exported_get",
                   BATATA_RUNTIME_EXPORTED_GET, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.exported_length", "ex.exported_length",
                   BATATA_RUNTIME_EXPORTED_LENGTH, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.func", "ex.func", BATATA_TARGET_FUNC_FUNC,
                   func_rewrite),
    BATATA_PATTERN("batata.ex.if", "ex.if", BATATA_TARGET_SCF_IF, if_rewrite),
    BATATA_PATTERN("batata.ex.lit", "ex.lit", BATATA_TARGET_ARITH_CONSTANT,
                   literal_rewrite),
    BATATA_PATTERN("batata.ex.mul", "ex.mul", BATATA_TARGET_ARITH_MULI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.process_table_reset", "ex.process_table_reset",
                   BATATA_RUNTIME_PROCESS_TABLE_RESET, runtime_call_rewrite),
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
    BATATA_PATTERN("batata.ex.sub", "ex.sub", BATATA_TARGET_ARITH_SUBI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.term_eq", "ex.term_eq", BATATA_RUNTIME_TERM_EQ,
                   runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_export", "ex.term_export",
                   BATATA_RUNTIME_TERM_EXPORT, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_handle_destroy", "ex.term_handle_destroy",
                   BATATA_RUNTIME_HANDLE_DESTROY, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_handle_export", "ex.term_handle_export",
                   BATATA_RUNTIME_HANDLE_EXPORT, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.term_import", "ex.term_import",
                   BATATA_RUNTIME_TERM_IMPORT, runtime_call_rewrite),
    BATATA_PATTERN("batata.ex.to_word", "ex.to_word", 0, identity_rewrite),
    BATATA_PATTERN("batata.ex.unbox", "ex.unbox", 0, identity_rewrite),
    BATATA_PATTERN("batata.ex.yield", "ex.yield", BATATA_TARGET_SCF_YIELD,
                   yield_rewrite),
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
