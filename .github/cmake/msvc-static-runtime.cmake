cmake_policy(SET CMP0091 NEW)

# The pinned Windows LLVM/MLIR distribution is built with the static MSVC
# runtime. Every CMake target linked with it must use the same runtime ABI.
set(
  CMAKE_MSVC_RUNTIME_LIBRARY
  "MultiThreaded$<$<CONFIG:Debug>:Debug>"
  CACHE STRING "MSVC runtime ABI required by the pinned LLVM distribution" FORCE
)
