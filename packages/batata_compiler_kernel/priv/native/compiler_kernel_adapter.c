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
};

extern int64_t batata_kernel_pattern_accept(int64_t actual_operands,
                                             int64_t actual_results,
                                             int64_t expected_operands,
                                             int64_t expected_results);
extern int64_t batata_kernel_target_length(int64_t kind);
extern int64_t batata_kernel_target_word(int64_t kind, int64_t index);
extern int64_t batata_kernel_cmp_predicate(int64_t length, int64_t word);
extern int64_t batata_kernel_runtime_arity(int64_t kind);

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
    BATATA_PATTERN("batata.ex.cmp", "ex.cmp", BATATA_TARGET_ARITH_CMPI,
                   cmp_rewrite),
    BATATA_PATTERN("batata.ex.div", "ex.div", BATATA_TARGET_ARITH_DIVSI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.lit", "ex.lit", BATATA_TARGET_ARITH_CONSTANT,
                   literal_rewrite),
    BATATA_PATTERN("batata.ex.mul", "ex.mul", BATATA_TARGET_ARITH_MULI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.rem", "ex.rem", BATATA_TARGET_ARITH_REMSI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.sub", "ex.sub", BATATA_TARGET_ARITH_SUBI,
                   binary_rewrite),
    BATATA_PATTERN("batata.ex.term_eq", "ex.term_eq", BATATA_RUNTIME_TERM_EQ,
                   runtime_call_rewrite),
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
      !host->ensureFunctionDeclaration)
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
