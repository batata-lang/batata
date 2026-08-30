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

extern int64_t batata_kernel_ex_add_decide(int64_t n_operands,
                                            int64_t has_result);
extern int64_t batata_kernel_ex_add_target_length(void);
extern int64_t batata_kernel_ex_add_target_word0(void);
extern int64_t batata_kernel_ex_add_target_word1(void);
extern int64_t batata_kernel_ex_add_target_word2(void);

static MlirLogicalResult report_failure(MlirStringCallback diagnostic,
                                        void *user_data,
                                        const char *message,
                                        intptr_t length) {
  if (diagnostic)
    diagnostic(mlirStringRefCreate(message, length), user_data);
  return mlirLogicalResultFailure();
}

static void decode_word(uint32_t word, char *output, intptr_t count) {
  for (intptr_t index = 0; index < count; ++index)
    output[index] = (char)((word >> (index * 8)) & 0xffu);
}

static MlirLogicalResult ex_add_rewrite(
    const MlirBeaverCompilerKernelHostAPI *host, MlirOperation operation,
    intptr_t n_operands, MlirValue *operands,
    MlirConversionPatternRewriter rewriter, MlirTypeConverter type_converter,
    void *user_data, MlirStringCallback diagnostic,
    void *diagnostic_user_data) {
  (void)user_data;

  MlirValue source_result;
  MlirType source_type;
  MlirType converted_type;
  MlirLocation location;

  if (mlirLogicalResultIsFailure(host->operationResult(
          operation, 0, &source_result, diagnostic, diagnostic_user_data)))
    return mlirLogicalResultFailure();

  if (batata_kernel_ex_add_decide((int64_t)n_operands, 1) != 1)
    return report_failure(
        diagnostic, diagnostic_user_data,
        "Batata ex.add source rejected the operation",
        sizeof("Batata ex.add source rejected the operation") - 1);

  if (mlirLogicalResultIsFailure(host->operationLocation(
          operation, &location, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->valueType(
          source_result, &source_type, diagnostic, diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->convertType(
          type_converter, source_type, &converted_type, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  int64_t target_length = batata_kernel_ex_add_target_length();
  if (target_length != 10)
    return report_failure(
        diagnostic, diagnostic_user_data,
        "Batata ex.add target encoding is invalid",
        sizeof("Batata ex.add target encoding is invalid") - 1);

  char target[10];
  decode_word((uint32_t)batata_kernel_ex_add_target_word0(), target, 4);
  decode_word((uint32_t)batata_kernel_ex_add_target_word1(), target + 4, 4);
  decode_word((uint32_t)batata_kernel_ex_add_target_word2(), target + 8, 2);

  MlirBeaverCompilerKernelOperation descriptor = {
      sizeof(MlirBeaverCompilerKernelOperation),
      mlirStringRefCreate(target, target_length),
      location,
      n_operands,
      operands,
      1,
      &converted_type,
      0,
      NULL,
  };

  MlirOperation replacement;
  MlirValue replacement_result;
  if (mlirLogicalResultIsFailure(host->createOperation(
          rewriter, &descriptor, &replacement, diagnostic,
          diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(host->operationResult(
          replacement, 0, &replacement_result, diagnostic,
          diagnostic_user_data)))
    return mlirLogicalResultFailure();

  return host->replaceOperationWithValues(
      rewriter, operation, 1, &replacement_result, diagnostic,
      diagnostic_user_data);
}

BATATA_KERNEL_EXPORT uint32_t batata_conversion_abi_version(void) {
  return MLIR_BEAVER_COMPILER_KERNEL_ABI_VERSION;
}

BATATA_KERNEL_EXPORT MlirStringRef batata_conversion_manifest(void) {
  static const char identity[] = BATATA_KERNEL_IDENTITY;
  return mlirStringRefCreate(identity, sizeof(identity) - 1);
}

BATATA_KERNEL_EXPORT MlirLogicalResult batata_populate_ex_patterns(
    MlirRewritePatternSet patterns, MlirTypeConverter type_converter,
    const MlirBeaverCompilerKernelHostAPI *host, void *host_context,
    MlirStringCallback diagnostic, void *diagnostic_user_data) {
  (void)diagnostic;
  (void)diagnostic_user_data;

  if (!host || host->abiVersion != MLIR_BEAVER_COMPILER_KERNEL_ABI_VERSION ||
      host->structSize < sizeof(MlirBeaverCompilerKernelHostAPI) ||
      !host->addPattern || !host->operationResult ||
      !host->operationLocation || !host->valueType || !host->convertType ||
      !host->createOperation || !host->replaceOperationWithValues)
    return mlirLogicalResultFailure();

  MlirBeaverCompilerKernelPattern pattern = {
      sizeof(MlirBeaverCompilerKernelPattern),
      mlirStringRefCreate("batata.ex.add", sizeof("batata.ex.add") - 1),
      mlirStringRefCreate("ex.add", sizeof("ex.add") - 1),
      mlirStringRefCreate("1", sizeof("1") - 1),
      1,
      ex_add_rewrite,
      NULL,
      NULL,
  };

  return host->addPattern(host_context, patterns, type_converter, &pattern);
}
