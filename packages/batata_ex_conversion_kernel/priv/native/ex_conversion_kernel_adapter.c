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

#define BATATA_MAX_VALUES 8
#define BATATA_MAX_BUILDER_VALUES 16

extern int64_t batata_kernel_target_length(int64_t kind);
extern int64_t batata_kernel_target_word(int64_t kind, int64_t index);
extern int64_t batata_kernel_pattern_count(void);
extern int64_t batata_kernel_pattern_namespace_length(void);
extern int64_t batata_kernel_pattern_namespace_word(int64_t index);
extern int64_t batata_kernel_pattern_root_length(int64_t pattern);
extern int64_t batata_kernel_pattern_root_word(int64_t pattern, int64_t index);
extern int64_t batata_kernel_rewrite(int64_t pattern);

typedef struct {
  char name[96];
  intptr_t name_length;
  char root[80];
  intptr_t root_length;
  int64_t pattern_id;
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
  MlirValue builder_operands[BATATA_MAX_BUILDER_VALUES];
  MlirType builder_results[BATATA_MAX_BUILDER_VALUES];
  MlirNamedAttribute builder_attributes[BATATA_MAX_BUILDER_VALUES];
  intptr_t builder_operand_count;
  intptr_t builder_result_count;
  intptr_t builder_attribute_count;
  MlirType function_inputs[BATATA_MAX_VALUES];
  MlirType function_results[BATATA_MAX_VALUES];
  intptr_t function_input_count;
  intptr_t function_result_count;
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

static int64_t block_handle(MlirBlock block) {
  return (int64_t)(intptr_t)block.ptr;
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

static MlirBlock block_from_handle(int64_t handle) {
  MlirBlock block = {(void *)(intptr_t)handle};
  return block;
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

int64_t batata_compiler_abi_attribute_integer_value(
    int64_t attribute_handle_value) {
  int64_t value;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->attributeIntegerValue(
          attribute_from_handle(attribute_handle_value), &value,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return value;
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
  if (!invocation ||
      invocation->builder_operand_count >= BATATA_MAX_BUILDER_VALUES)
    return fail_invocation();
  invocation->builder_operands[invocation->builder_operand_count++] =
      value_from_handle(value_handle_value);
  return 1;
}

int64_t batata_compiler_abi_builder_add_result_type(
    int64_t type_handle_value) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      invocation->builder_result_count >= BATATA_MAX_BUILDER_VALUES)
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
  if (!invocation ||
      invocation->builder_attribute_count >= BATATA_MAX_BUILDER_VALUES ||
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

static int64_t add_flat_symbol_attribute(MlirStringRef symbol,
                                         int64_t name_id) {
  char name_storage[80];
  MlirStringRef name;
  MlirAttribute attribute;
  MlirNamedAttribute named_attribute;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      invocation->builder_attribute_count >= BATATA_MAX_BUILDER_VALUES ||
      mlirLogicalResultIsFailure(target_name(
          name_id, name_storage, sizeof(name_storage), &name,
          invocation->diagnostic, invocation->diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(invocation->host->flatSymbolRefAttribute(
          invocation->rewriter, symbol, &attribute, invocation->diagnostic,
          invocation->diagnostic_user_data)) ||
      mlirLogicalResultIsFailure(invocation->host->namedAttribute(
          invocation->rewriter, name, attribute, &named_attribute,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  invocation->builder_attributes[invocation->builder_attribute_count++] =
      named_attribute;
  return 1;
}

int64_t batata_compiler_abi_builder_add_flat_symbol(
    int64_t name_id, int64_t symbol_id) {
  char symbol_storage[80];
  MlirStringRef symbol;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(target_name(
          symbol_id, symbol_storage, sizeof(symbol_storage), &symbol,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return add_flat_symbol_attribute(symbol, name_id);
}

int64_t batata_compiler_abi_builder_add_flat_symbol_from_attribute(
    int64_t name_id, int64_t attribute_handle_value) {
  MlirStringRef symbol;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->attributeStringValue(
          attribute_from_handle(attribute_handle_value), &symbol,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return add_flat_symbol_attribute(symbol, name_id);
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

int64_t batata_compiler_abi_operation_region_count(void) {
  intptr_t count;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationRegionCount(
          invocation->operation, &count, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return count;
}

int64_t batata_compiler_abi_single_region_block(int64_t region_index) {
  MlirBlock block;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->singleRegionBlock(
          invocation->operation, region_index, &block, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return block_handle(block);
}

int64_t batata_compiler_abi_block_argument_count(int64_t block_handle_value) {
  intptr_t count;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->blockArgumentCount(
          block_from_handle(block_handle_value), &count, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return count;
}

int64_t batata_compiler_abi_block_argument(int64_t block_handle_value,
                                            int64_t index) {
  MlirValue argument;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->blockArgument(
          block_from_handle(block_handle_value), index, &argument,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return value_handle(argument);
}

int64_t batata_compiler_abi_block_terminator(int64_t block_handle_value) {
  MlirOperation terminator;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->blockTerminator(
          block_from_handle(block_handle_value), &terminator,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return operation_handle(terminator);
}

static int64_t operation_count(int64_t operation_handle_value,
                               int want_results) {
  intptr_t operands;
  intptr_t results;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationCounts(
          operation_from_handle(operation_handle_value), &operands, &results,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return want_results ? results : operands;
}

int64_t batata_compiler_abi_operation_operand_count(
    int64_t operation_handle_value) {
  return operation_count(operation_handle_value, 0);
}

int64_t batata_compiler_abi_operation_result_count(
    int64_t operation_handle_value) {
  return operation_count(operation_handle_value, 1);
}

int64_t batata_compiler_abi_operation_operand(int64_t operation_handle_value,
                                               int64_t index) {
  MlirValue operand;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->operationOperand(
          operation_from_handle(operation_handle_value), index, &operand,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return value_handle(operand);
}

int64_t batata_compiler_abi_function_type_reset(void) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation)
    return fail_invocation();
  invocation->function_input_count = 0;
  invocation->function_result_count = 0;
  return 1;
}

int64_t batata_compiler_abi_function_type_add_input(
    int64_t type_handle_value) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation || invocation->function_input_count >= BATATA_MAX_VALUES)
    return fail_invocation();
  invocation->function_inputs[invocation->function_input_count++] =
      type_from_handle(type_handle_value);
  return 1;
}

int64_t batata_compiler_abi_function_type_add_result(
    int64_t type_handle_value) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation || invocation->function_result_count >= BATATA_MAX_VALUES)
    return fail_invocation();
  invocation->function_results[invocation->function_result_count++] =
      type_from_handle(type_handle_value);
  return 1;
}

int64_t batata_compiler_abi_function_type_create(void) {
  MlirType type;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->functionType(
          invocation->rewriter, invocation->function_input_count,
          invocation->function_inputs, invocation->function_result_count,
          invocation->function_results, &type, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return type_handle(type);
}

int64_t batata_compiler_abi_type_attribute(int64_t type_handle_value) {
  MlirAttribute attribute;
  BatataInvocation *invocation = current_invocation;
  if (!invocation ||
      mlirLogicalResultIsFailure(invocation->host->typeAttribute(
          type_from_handle(type_handle_value), &attribute,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return attribute_handle(attribute);
}

int64_t batata_compiler_abi_builder_create_with_regions(int64_t region_count) {
  MlirOperation operation;
  BatataInvocation *invocation = current_invocation;
  if (!invocation || region_count < 0 || region_count > 2)
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
  if (mlirLogicalResultIsFailure(invocation->host->createOperationWithRegions(
          invocation->rewriter, &descriptor, region_count, &operation,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return operation_handle(operation);
}

int64_t batata_compiler_abi_replace_regions(int64_t operation_handle_value,
                                            int64_t region_count) {
  BatataInvocation *invocation = current_invocation;
  if (!invocation || region_count < 0 || region_count > 2 ||
      mlirLogicalResultIsFailure(invocation->host->replaceOperationWithRegions(
          invocation->rewriter, operation_from_handle(operation_handle_value),
          invocation->operation, region_count, invocation->diagnostic,
          invocation->diagnostic_user_data)))
    return fail_invocation();
  return 1;
}

int64_t batata_compiler_abi_builder_prepare_call(int64_t symbol_id,
                                                 int64_t callee_name_id,
                                                 int64_t result_type_handle) {
  char symbol_storage[80];
  MlirStringRef symbol;
  MlirType input_types[BATATA_MAX_BUILDER_VALUES];
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

  invocation->builder_result_count = 1;
  invocation->builder_results[0] = result_type;
  if (add_flat_symbol_attribute(symbol, callee_name_id) != 1)
    return fail_invocation();
  return 1;
}

int64_t batata_compiler_abi_builder_create_call(int64_t symbol_id,
                                                int64_t callee_name_id,
                                                int64_t result_type_handle) {
  if (batata_compiler_abi_builder_prepare_call(
          symbol_id, callee_name_id, result_type_handle) != 1)
    return fail_invocation();
  return batata_compiler_abi_builder_create();
}

int64_t batata_compiler_abi_llvm_pointer_type(int64_t address_space) {
  MlirType type;
  BatataInvocation *invocation = current_invocation;
  if (!invocation || address_space < 0 || address_space > UINT32_MAX ||
      mlirLogicalResultIsFailure(invocation->host->llvmPointerType(
          invocation->rewriter, (unsigned)address_space, &type,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return type_handle(type);
}

int64_t batata_compiler_abi_dense_i32_array_attribute(int64_t count,
                                                       int64_t first,
                                                       int64_t second) {
  int32_t values[2];
  MlirAttribute attribute;
  BatataInvocation *invocation = current_invocation;
  if (!invocation || count < 0 || count > 2 || first < INT32_MIN ||
      first > INT32_MAX || second < INT32_MIN || second > INT32_MAX)
    return fail_invocation();
  values[0] = (int32_t)first;
  values[1] = (int32_t)second;
  if (mlirLogicalResultIsFailure(invocation->host->denseI32ArrayAttribute(
          invocation->rewriter, count, count == 0 ? NULL : values, &attribute,
          invocation->diagnostic, invocation->diagnostic_user_data)))
    return fail_invocation();
  return attribute_handle(attribute);
}

int64_t batata_compiler_abi_builder_create_at_block_start(
    int64_t block_handle_value) {
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
  if (mlirLogicalResultIsFailure(
          invocation->host->createOperationAtBlockStart(
              invocation->rewriter, block_from_handle(block_handle_value),
              &descriptor, &operation, invocation->diagnostic,
              invocation->diagnostic_user_data)))
    return fail_invocation();
  return operation_handle(operation);
}

int64_t batata_compiler_abi_builder_create_before(
    int64_t operation_handle_value) {
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
  if (mlirLogicalResultIsFailure(invocation->host->createOperationBefore(
          invocation->rewriter, operation_from_handle(operation_handle_value),
          &descriptor, &operation, invocation->diagnostic,
          invocation->diagnostic_user_data)))
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
      !host->operationRegionCount)
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
    if (mlirLogicalResultIsFailure(decode_pattern_root(
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
        source_rewrite,
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
