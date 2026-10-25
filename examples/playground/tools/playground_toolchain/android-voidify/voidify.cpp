// The compiler's Swift-written modules (SIL, Optimizer) reference libc++'s
// std::__voidify for a few C++ types through the clang importer, but the
// inline instantiations are never emitted on the Android host build (hidden
// visibility, no defining object). Explicit instantiations, linked into
// swift-frontend, satisfy them.
#include <memory>
#include "swift/SIL/SILType.h"
#include "swift/SIL/SILLocation.h"
#include "swift/SIL/SILDebugVariable.h"
#include "swift/SIL/SILInstruction.h"
#include "llvm/Support/Alignment.h"

template void *std::__voidify<swift::SILType>(swift::SILType &);
template void *std::__voidify<swift::SILLocation>(swift::SILLocation &);
template void *std::__voidify<swift::SILDebugVariable>(swift::SILDebugVariable &);
template void *std::__voidify<swift::FixedOperandList<1u>>(swift::FixedOperandList<1u> &);
template void *std::__voidify<llvm::Align>(llvm::Align &);
